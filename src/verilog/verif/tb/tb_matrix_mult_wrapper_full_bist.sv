`timescale 1ns/1ps
`include "mm_verif_defs.svh"
import matrix_mult_pkg::*;

// Wrapper-level direct external-mode stimulus.
// Bound checkers verify wrapper routing and core arithmetic.
module tb_matrix_mult_wrapper_full_bist;
    logic clk_i=0;
    always #4 clk_i=~clk_i;
    logic rstn_i=0, ext_en_i=1, start_i=0;
    logic en_i = 1'b1;
    // Power for the post-APR netlist, which has VDD/VSS ports. .* only connects ports that exist
    supply1 VDD;
    supply0 VSS;
    wire rstn_async_i;
    test_config_struct test_config_i;

 assign rstn_async_i = rstn_i;

logic bist_run = 1'b0;
logic [63:0] bist_stop_code = '0;
always_comb begin
    test_config_i = '0;

    // Use driver, compute core and signature analyzer.
    test_config_i.bypass = 3'b000;
    test_config_i.mode = 2'b00;

    test_config_i.driver_valid = bist_run;
    test_config_i.driver_stop_code = bist_stop_code;
end
    external_inputs_struct ext_inputs_i='0;
    data_config_struct data_config_i='0;
    logic [WIDTH*(ROW+COL)-1:0] ext_result_o;
    logic ext_valid_o, done_o;
    extra_output_bits_struct extra_output_bits_o;
    logic ob_mem_cenb_R_o, ob_mem_wenb_R_o, ob_mem_cenb_W_o, ob_mem_wenb_W_o;
    logic ib_mem_cenb_o, ib_mem_wenb_o, wb_mem_cenb_o, wb_mem_wenb_o;
    logic [$clog2(O_SIZE)-1:0] ob_mem_addr_R_o, ob_mem_addr_W_o;
    logic [$clog2(I_SIZE)-1:0] ib_mem_addr_o;
    logic [$clog2(W_SIZE)-1:0] wb_mem_addr_o;
    logic [COL-1:0][15:0] ob_mem_data_R_o, ob_mem_data_W_o;
    logic [COL-1:0][15:0] ob_mem_data_R_i='x, ob_mem_data_W_i='x;
    logic [ROW-1:0][WIDTH-1:0] ib_mem_data_i='x;
    logic [COL-1:0][WIDTH-1:0] wb_mem_data_i='x;
    matrix_mult_wrapper_9 dut (.*);
    int rows_received=0;
    always @(posedge clk_i) if (rstn_i && ext_valid_o) rows_received++;

    task automatic tick(input int cycles=1);
        repeat(cycles) @(negedge clk_i);
    endtask
    task automatic reset_core;
        rstn_i=0;
        ext_inputs_i='0;
        tick(3);
        rstn_i=1;
        tick(4);
    endtask
    task automatic run_tile(input int kind, input int nrows, input bit bubbles);
        int before_count;
        logic [COL-1:0][WIDTH-1:0] weights[ROW];
        for(int k=0;k<ROW;k++)
            for(int j=0;j<COL;j++) begin
                case(kind)
                    0: weights[k][j] = WIDTH'(k==j);
                    1: weights[k][j] = 8'h80;
                    2: weights[k][j] = 8'h7f;
                    3: weights[k][j] = k%2 ? 8'h7f : 8'h81;
                    4: weights[k][j] = '0;
                    default: weights[k][j] = WIDTH'($urandom);
                endcase
            end
        before_count=rows_received;
        for(int k=ROW-1;k>=0;k--) begin
            ext_inputs_i.ext_weight_en=1;
            ext_inputs_i.ext_weight=weights[k];
            tick();
        end
        ext_inputs_i.ext_weight_en=0;
        for(int r=0;r<nrows;r++) begin
            if(bubbles && r%3==1) begin
                ext_inputs_i.ext_valid=0;
                tick(2);
            end
            ext_inputs_i.ext_valid=1;
            for(int k=0;k<ROW;k++) begin
                case(kind)
                    1: ext_inputs_i.ext_input[k]=8'h80;
                    2: ext_inputs_i.ext_input[k]=8'h80;
                    3: ext_inputs_i.ext_input[k]=8'h7f;
                    default: ext_inputs_i.ext_input[k]=WIDTH'($urandom);
                endcase
            end
            // ext_psum is intentionally nonzero: TA model does not use it.
            ext_inputs_i.ext_psum=$urandom;
            tick();
        end
        ext_inputs_i.ext_valid=0;
        tick(ROW+COL+3);
        a_row_count: assert(rows_received-before_count==nrows)
            else `SVA_FAIL("WRAPPER REGISTERED EXTERNAL test lost or duplicated output rows")
    endtask

    // Independent reference for the implemented 64-bit feedback recurrence.
function automatic logic [63:0] lfsr_step(input logic [63:0] value);
    return {value[62:0], value[63] ^ value[62] ^ value[61] ^ value[52]};
endfunction

// MISR keeps the TA's original one-based taps; it differs from the LFSR.
function automatic logic [63:0] misr_step(input logic [63:0] value);
    return {value[62:0], value[62] ^ value[61] ^ value[60] ^ value[51]};
endfunction

initial begin : full_bist_test
    logic [63:0] expected_driver;
    logic [63:0] expected_signature;
    logic [63:0] expected_result;
    logic [COL-1:0][WIDTH-1:0] weights[ROW];
    logic [ROW-1:0][WIDTH-1:0] activation;
    int signed dot_product;
    int wait_cycles;
    bit any_sat = 1'b0;
    logic [7:0] page, in_count;
    logic [WIDTH-1:0] weight_xor = '0;

    // This directed test targets the default 4x4, int8 configuration.
    if (WIDTH != 8 || ROW != 4 || COL != 4)
        $fatal(1, "Full BIST test requires WIDTH=8, ROW=4, COL=4");

    rstn_i = 0;
    bist_run = 0;
    ext_inputs_i = '0;

    // Driver seed = {ext_input, ext_psum}.
    // Use nonzero activation bytes to exercise the compute core.
    ext_inputs_i.ext_input = 32'h0102_0304;
    ext_inputs_i.ext_psum  = 32'h0506_0708;

    expected_driver = {
        ext_inputs_i.ext_input,
        ext_inputs_i.ext_psum
    };

    // Monitor seed uses the opposite packing.
    expected_signature = {
        ext_inputs_i.ext_psum,
        ext_inputs_i.ext_input
    };

    // Mixed positive, negative and zero weights.
    for (int k=0; k<ROW; k++)
        for (int j=0; j<COL; j++)
            weights[k][j] = WIDTH'(((k+j)%5)-2);

    // Predict 64 LFSR samples, their matrix results,
    // and the final MISR signature. Beyond 32 samples, new feedback bits
    // reach the activation half, exercising the corrected TA LFSR taps.
    for (int n=0; n<64; n++) begin
        expected_driver = lfsr_step(expected_driver);

        // The wrapper routes the upper 32 driver bits to activations.
        activation = expected_driver[63:32];
        expected_result = '0;

        for (int j=0; j<COL; j++) begin
            dot_product = 0;

            for (int k=0; k<ROW; k++)
                dot_product +=
                    int'($signed(activation[k])) *
                    int'($signed(weights[k][j]));

            // Saturate after the full dot product.
            if (dot_product > 127 || dot_product < -128)
                any_sat = 1'b1;
            if (dot_product > 127)
                dot_product = 127;
            else if (dot_product < -128)
                dot_product = -128;

            // Core output occupies the low 32 wrapper bits.
            expected_result[j*WIDTH +: WIDTH] =
                WIDTH'(dot_product);
        end

        expected_signature =
            misr_step(expected_signature) ^ expected_result;
    end

    // Stop when the driver reaches its 64th generated sample.
    bist_stop_code = expected_driver;

    tick(3);
    rstn_i = 1;
    tick(4);

    // Load weight rows in reverse order, while the driver is paused.
    for (int k=ROW-1; k>=0; k--) begin
        ext_inputs_i.ext_weight_en = 1;
        ext_inputs_i.ext_weight = weights[k];
        tick();
    end

    ext_inputs_i.ext_weight_en = 0;
    bist_run = 1;

    wait_cycles = 0;
    while (!ext_valid_o && wait_cycles < 100) begin
        tick();
        wait_cycles++;
    end

    if (!ext_valid_o)
        $fatal(1, "Full BIST timeout waiting for signature");

    if (ext_result_o !== expected_signature)
        $fatal(
            1,
            "Full BIST signature mismatch: expected=%h actual=%h",
            expected_signature,
            ext_result_o
        );

    // Completed signature and valid must remain stable.
    repeat (3) begin
        tick();

        if (ext_valid_o !== 1'b1 ||
            ext_result_o !== expected_signature)
            $fatal(1, "Full BIST signature or valid did not remain stable");
    end

    // Debug add-on pages in BiST mode, read through the static scan bits. The
    // memory controller is held in reset, so only the array-side pages move.
    for (int k=0; k<ROW; k++)
        for (int j=0; j<COL; j++)
            weight_xor ^= weights[k][j];

    data_config_i.extra_config_i = {3'd0, 1'b0};
    tick();
    if (extra_output_bits_o.extra_config_o !== 8'h10)
        $fatal(1, "Full BIST debug status page %h, expected ext_en only (10)",
               extra_output_bits_o.extra_config_o);

    data_config_i.extra_config_i = {3'd4, 1'b0};
    tick();
    if (extra_output_bits_o.extra_config_o !== weight_xor)
        $fatal(1, "Full BIST debug weight checksum %h, expected %h",
               extra_output_bits_o.extra_config_o, weight_xor);

    // Every driver sample is one input row and one output row
    data_config_i.extra_config_i = {3'd6, 1'b0};
    tick();
    in_count = extra_output_bits_o.extra_config_o;
    data_config_i.extra_config_i = {3'd5, 1'b0};
    tick();
    if (in_count !== 8'd64 || extra_output_bits_o.extra_config_o !== 8'd64)
        $fatal(1, "Full BIST debug row counts in=%0d out=%0d, expected 64",
               in_count, extra_output_bits_o.extra_config_o);

    // Weight load, input valid and output valid seen; no 16-bit psum writes in
    // BiST; the 8-bit flag follows the predicted dot products
    data_config_i.extra_config_i = {3'd7, 1'b0};
    tick();
    page = extra_output_bits_o.extra_config_o;
    if (page !== {3'b111, 3'b000, any_sat, 1'b0})
        $fatal(1, "Full BIST debug event flags %b, expected %b",
               page, {3'b111, 3'b000, any_sat, 1'b0});

    $display(
        "WRAPPER FULL BIST: signature=%h assertion errors=%0d",
        ext_result_o,
        mm_verif_pkg::sva_errors
    );

    if (mm_verif_pkg::sva_errors != 0)
        $fatal(1, "WRAPPER FULL BIST FAILED");

    $display("WRAPPER FULL BIST PASSED");
    $finish;
end
    initial begin
        #1000000;
        $fatal(1,"WRAPPER REGISTERED EXTERNAL timeout");
    end
endmodule
