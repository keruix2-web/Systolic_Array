`include "mm_verif_defs.svh"

// End-to-end accounting around the driver -> DUT -> monitor pipeline.
// Arithmetic and signature recurrences are checked by the other bound checkers.
module bist_checker #(parameter Tk=4, Tn=4) (
    input logic g_clk, rstn_i, ext_en_i,
    input logic driver_bypass_w, driver_mode_w, dut_bypass_w, sa_bypass_w, sa_mode_w,
    input logic driver_done_w, ext_valid_i_w, sa_dut_valid_w, sa_stop_w, sa_valid_w
);
    localparam LATENCY = Tk + Tn - 1;
    logic [LATENCY:0] stop_reference;
    logic active;
    int unsigned inputs_seen, outputs_seen;
    assign active = ext_en_i && !driver_bypass_w && !driver_mode_w;
    always_ff @(posedge g_clk) begin
        if (!rstn_i || !active) begin
            stop_reference <= '0;
            inputs_seen <= 0;
            outputs_seen <= 0;
        end else begin
            stop_reference[0] <= driver_done_w;
            for (int d=1; d<=LATENCY; d++) stop_reference[d] <= stop_reference[d-1];
            if (ext_valid_i_w) inputs_seen <= inputs_seen + 1;
            if (sa_dut_valid_w) outputs_seen <= outputs_seen + 1;
        end
    end
    default clocking cb @(posedge g_clk); endclocking
    default disable iff (!rstn_i);
    a_stop_alignment: assert property (active |-> sa_stop_w ==
        (dut_bypass_w ? stop_reference[0] : stop_reference[LATENCY]))
        else `SVA_FAIL("BiST monitor stop is not aligned with pipeline draining")
    a_no_early_stop: assert property (active && sa_stop_w |->
        inputs_seen == outputs_seen && !sa_dut_valid_w)
        else `SVA_FAIL("BiST stopped before every input result reached monitor")
    a_signature_ready: assert property (active && !sa_mode_w && !sa_bypass_w && sa_stop_w |=> sa_valid_w)
        else `SVA_FAIL("BiST signature not valid after completion")
    c_full_bist: cover property (active && !dut_bypass_w && !sa_mode_w && !sa_bypass_w &&
                                sa_stop_w && inputs_seen != 0);
    c_loopback_bist: cover property (active && dut_bypass_w && sa_stop_w && inputs_seen != 0);
endmodule
