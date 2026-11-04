`include "mm_verif_defs.svh"

// Independent port-level model of the external weight-loading protocol.
module external_controller_checker #(parameter Tk=4) (
    input logic clk_i, rstn_i, ext_en_i, ext_weight_en_i, ext_valid_i,
    input logic load_weight_o, write_weight_o, act_valid_o
);
    int unsigned rows_seen;
    logic ready;
    always_ff @(posedge clk_i) begin
        if (!rstn_i || !ext_en_i) begin
            rows_seen <= 0;
            ready <= 0;
        end else if (ext_weight_en_i) begin
            if (rows_seen == Tk-1) begin
                rows_seen <= 0;
                ready <= 1;
            end else begin
                rows_seen <= rows_seen + 1;
                ready <= 0;
            end
        end else rows_seen <= 0;
    end
    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);
    a_load: assert property (load_weight_o == (ext_en_i && ext_weight_en_i))
        else `SVA_FAIL("external load enable mismatch")
    a_commit: assert property (write_weight_o == (ext_en_i && ext_weight_en_i && rows_seen == Tk-1))
        else `SVA_FAIL("external weights must commit on row Tk")
    a_activation: assert property (act_valid_o == (ext_en_i && ready && !ext_weight_en_i && ext_valid_i))
        else `SVA_FAIL("external activation enable mismatch")
    a_complete_burst: assert property (ext_en_i && rows_seen != 0 |-> ext_weight_en_i)
        else `SVA_FAIL("external weights require Tk consecutive rows, bottom row first")
    a_input_after_weights: assert property (ext_en_i && ext_valid_i && !ext_weight_en_i |-> ready)
        else `SVA_FAIL("external activation supplied before a complete weight tile")
    a_no_load_and_input: assert property (ext_en_i |-> !(ext_valid_i && ext_weight_en_i))
        else `SVA_FAIL("external weights and activations supplied together")
    c_load_then_input: cover property (write_weight_o ##1 act_valid_o);
    c_input_bubble: cover property (act_valid_o ##1 (!act_valid_o)[*1:3] ##1 act_valid_o);
endmodule
