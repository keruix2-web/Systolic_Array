`timescale 1ns/1ps
`include "mm_verif_defs.svh"
import matrix_mult_pkg::*;

// Core-only external stimulus. Wrapper-level stimulus belongs to teammate C.
// Bound checkers verify arithmetic, exact latency, routing and memory isolation.
module tb_matrix_mult_external;
    logic clk_i=0;
    always #4 clk_i=~clk_i;
    logic rstn_i=0, ext_en_i=1, start_i=0;
    external_inputs_struct ext_inputs_i='0;
    data_config_struct data_config_i='0;
    logic [COL-1:0][WIDTH-1:0] ext_result_o;
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
    matrix_mult_9 dut (.*);
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
        tick();
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
            else `SVA_FAIL("external core test lost or duplicated output rows")
    endtask

    initial begin
        int seed=8804;
        seed=$urandom(seed);
        reset_core();
        // External operation is independent of the memory start signal.
        start_i=1;
        for(int kind=0;kind<5;kind++) run_tile(kind,4,0);
        for(int t=0;t<100;t++) run_tile(5,4+(t%5)*4,t%2);
        // Abort a run while results are in flight, then verify a fresh tile.
        ext_inputs_i.ext_valid=1;
        tick(2);
        reset_core();
        run_tile(0,4,0);
        // Returning idle with start held high must not launch a memory run.
        ext_en_i=0;
        tick(4);
        a_no_phantom_start: assert(ib_mem_cenb_o && wb_mem_cenb_o && ob_mem_cenb_W_o)
            else `SVA_FAIL("returning from external mode generated a phantom memory start")
        rstn_i=0;
        tick(2);
        $display("EXTERNAL CORE: 106 tiles, %0d output rows, assertion errors=%0d",
                 rows_received, mm_verif_pkg::sva_errors);
        if(mm_verif_pkg::sva_errors!=0) $fatal(1,"EXTERNAL CORE FAILED");
        $display("EXTERNAL CORE PASSED");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"external core timeout");
    end
endmodule
