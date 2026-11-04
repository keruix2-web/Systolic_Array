`include "mm_verif_defs.svh"

// External-port GEMM reference, independent of controller/PE internal arithmetic.
module matrix_mult_external_checker
    import matrix_mult_pkg::*;
    #(parameter WIDTH=8, Tm=4, Tn=4, Tk=4) (
    input logic clk_i, rstn_i, ext_en_i,
    input external_inputs_struct ext_inputs_i,
    input logic [Tn-1:0][WIDTH-1:0] ext_result_o,
    input logic ext_valid_o,
    input logic ib_mem_cenb_o, ib_mem_wenb_o, wb_mem_cenb_o, wb_mem_wenb_o,
    input logic ob_mem_cenb_R_o, ob_mem_wenb_R_o,
    input logic ob_mem_cenb_W_o, ob_mem_wenb_W_o,
    input logic load_weight, write_weight, act_valid,
    input logic [Tn-1:0][WIDTH-1:0] array_weight,
    input logic [Tk-1:0][WIDTH-1:0] array_activation
);
    localparam LATENCY = Tk + Tn - 1;
    typedef logic [Tn-1:0][WIDTH-1:0] row_t;
    row_t weight_history[Tk], weights[Tk], expected[LATENCY];
    logic [LATENCY-1:0] expected_valid;
    int unsigned rows_seen;
    logic ready;
    function automatic row_t golden_row(logic [Tk-1:0][WIDTH-1:0] activation);
        row_t result;
        longint signed sum;
        for (int j=0; j<Tn; j++) begin
            sum = 0;
            for (int k=0; k<Tk; k++)
                sum += longint'($signed(activation[k])) * longint'($signed(weights[k][j]));
            if (sum > ((64'sd1 << (WIDTH-1))-1)) sum = (64'sd1 << (WIDTH-1))-1;
            if (sum < -(64'sd1 << (WIDTH-1))) sum = -(64'sd1 << (WIDTH-1));
            result[j] = WIDTH'(sum);
        end
        return result;
    endfunction
    always_ff @(posedge clk_i) begin
        if (!rstn_i || !ext_en_i) begin
            expected_valid <= '0;
            rows_seen <= 0;
            ready <= 0;
            for (int k=0; k<Tk; k++) begin
                weight_history[k] <= '0;
                weights[k] <= '0;
            end
            for (int d=0; d<LATENCY; d++) expected[d] <= '0;
        end else begin
            if (ext_inputs_i.ext_weight_en) begin
                weight_history[0] <= ext_inputs_i.ext_weight;
                for (int k=1; k<Tk; k++) weight_history[k] <= weight_history[k-1];
                if (rows_seen == Tk-1) begin
                    weights[0] <= ext_inputs_i.ext_weight;
                    for (int k=1; k<Tk; k++) weights[k] <= weight_history[k-1];
                    rows_seen <= 0;
                    ready <= 1;
                end else begin
                    rows_seen <= rows_seen + 1;
                    ready <= 0;
                end
            end else rows_seen <= 0;
            expected_valid[0] <= ext_inputs_i.ext_valid && ready && !ext_inputs_i.ext_weight_en;
            expected[0] <= golden_row(ext_inputs_i.ext_input);
            for (int d=1; d<LATENCY; d++) begin
                expected_valid[d] <= expected_valid[d-1];
                expected[d] <= expected[d-1];
            end
        end
    end
    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);
    a_no_memory: assert property (ext_en_i |-> ib_mem_cenb_o && ib_mem_wenb_o &&
        wb_mem_cenb_o && wb_mem_wenb_o && ob_mem_cenb_R_o && ob_mem_wenb_R_o &&
        ob_mem_cenb_W_o && ob_mem_wenb_W_o)
        else `SVA_FAIL("memory access during external mode")
    a_valid_exact: assert property (ext_en_i |-> ext_valid_o == expected_valid[LATENCY-1])
        else `SVA_FAIL("external valid missing, extra, or at wrong latency")
    a_result: assert property (ext_en_i && ext_valid_o |-> ext_result_o == expected[LATENCY-1])
        else `SVA_FAIL("external result differs from signed saturated GEMM")
    a_memory_mode_quiet: assert property (!ext_en_i |-> !ext_valid_o)
        else `SVA_FAIL("external result valid outside external mode")
    a_weight_mux: assert property (ext_en_i && load_weight |-> array_weight == ext_inputs_i.ext_weight)
        else `SVA_FAIL("external weight mux mismatch")
    a_input_mux: assert property (ext_en_i && act_valid |-> array_activation == ext_inputs_i.ext_input)
        else `SVA_FAIL("external activation mux mismatch")
    a_no_reload_in_flight: assert property (ext_en_i && ext_inputs_i.ext_weight_en |-> !(|expected_valid))
        else `SVA_FAIL("weights reloaded before external results drained")
    a_mode_stable_in_flight: assert property ((|expected_valid) |-> ext_en_i)
        else `SVA_FAIL("external mode changed before results drained")
    a_known_output: assert property (ext_valid_o |-> !$isunknown(ext_result_o))
        else `SVA_FAIL("external output contains X/Z")
    c_back_to_back: cover property (ext_valid_o[*4]);
    c_bubble: cover property (ext_valid_o ##1 (!ext_valid_o)[*1:3] ##1 ext_valid_o);
    for (genvar j=0; j<Tn; j++) begin : lane_coverage
        c_positive_sat: cover property (ext_valid_o && $signed(ext_result_o[j]) == (1 << (WIDTH-1))-1);
        c_negative_sat: cover property (ext_valid_o && $signed(ext_result_o[j]) == -(1 << (WIDTH-1)));
    end
endmodule
