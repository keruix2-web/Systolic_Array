`timescale 1ns/1ps
`include "mm_verif_defs.svh"
import matrix_mult_pkg::*;

// Wrapper-level direct external-mode stimulus.
// Bound checkers verify wrapper routing and core arithmetic.
module tb_matrix_mult_wrapper_bist;
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

always_comb begin
    test_config_i = '0;

    // Driver and monitor active; compute core bypassed.
    test_config_i.bypass = 3'b010;

    // LFSR generation and MISR compression.
    test_config_i.mode = 2'b00;
    test_config_i.driver_valid = bist_run;

    // Starting at 1, twelve shifts reach 4096.
    test_config_i.driver_stop_code = 64'h0000_0000_0000_1000;
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

initial begin : bist_loopback_test
    logic [63:0] expected_driver;
    logic [63:0] expected_signature;
    int wait_cycles;

    if (WIDTH*(ROW+COL) != 64)
        $fatal(1, "This BIST test requires a 64-bit driver");

    rstn_i = 0;
    bist_run = 0;
    ext_inputs_i = '0;

    // Driver seed = {ext_input, ext_psum} = 64'h1.
    ext_inputs_i.ext_psum = 1;

    // Monitor seed uses the opposite packing:
    // {ext_psum, ext_input} = 64'h00000001_00000000.
    expected_driver = 64'h1;
    expected_signature = {
        ext_inputs_i.ext_psum,
        ext_inputs_i.ext_input
    };

    // Predict twelve generated samples and their compressed signature.
    for (int n=0; n<12; n++) begin
        expected_driver = lfsr_step(expected_driver);
        expected_signature =
            misr_step(expected_signature) ^ expected_driver;
    end

    // Hold reset, then allow the wrapper reset synchronizer to settle.
    tick(3);
    rstn_i = 1;
    tick(4);

    bist_run = 1;

    // Wait for the final signature, with a bounded timeout.
    wait_cycles = 0;
    while (!ext_valid_o && wait_cycles < 100) begin
        tick();
        wait_cycles++;
    end

    if (!ext_valid_o)
        $fatal(1, "BIST timeout waiting for signature");

    if (ext_result_o !== expected_signature)
        $fatal(
            1,
            "BIST signature mismatch: expected=%h actual=%h",
            expected_signature,
            ext_result_o
        );

    // The completed signature must remain stable.
    repeat (3) begin
        tick();
        if (ext_valid_o !== 1'b1 ||
            ext_result_o !== expected_signature)
            $fatal(1, "BIST signature or valid did not remain stable");
    end

    $display(
        "WRAPPER BIST LOOPBACK: signature=%h assertion errors=%0d",
        ext_result_o,
        mm_verif_pkg::sva_errors
    );

    if (mm_verif_pkg::sva_errors != 0)
        $fatal(1, "WRAPPER BIST LOOPBACK FAILED");

    $display("WRAPPER BIST LOOPBACK PASSED");
    $finish;
end
    initial begin
        #1000000;
        $fatal(1,"WRAPPER REGISTERED EXTERNAL timeout");
    end
endmodule
