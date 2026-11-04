/******************************************************************************
 Module Name : PE_checker
 Description :
     Assertions and coverage for one PE. Bound to every PE instance in
     mm_binds.sv, so it can see the internal weight register.

     Checks:
       - east_o is west_i delayed by one cycle
       - weight loading passes north_i straight to south_o
       - MAC mode computes south_o = weight * west_i + north_i with no overflow
       - weight only changes on write_weight_i, and only while loading
     Coverage:
       - weight x activation corner values for the MACs this PE performs
*******************************************************************************/

`include "mm_verif_defs.svh"

module PE_checker
    #(
        parameter   ACT_WIDTH=8,
        parameter   WEIGHT_WIDTH=8,
        parameter   INTERNAL_SUM_WIDTH=18
    )
    (
        input logic                                 clk_i,
        input logic                                 rstn_i,
        input logic                                 load_weight_i,
        input logic                                 write_weight_i,
        input logic signed [ACT_WIDTH-1:0]          west_i,
        input logic signed [INTERNAL_SUM_WIDTH-1:0] north_i,
        input logic signed [ACT_WIDTH-1:0]          east_o,
        input logic signed [INTERNAL_SUM_WIDTH-1:0] south_o,
        input logic signed [WEIGHT_WIDTH-1:0]       weight_r
    );

    // Range of the internal partial sum and the 8-bit operands
    localparam longint SUM_MAX = (longint'(1) <<< (INTERNAL_SUM_WIDTH-1)) - 1;
    localparam longint SUM_MIN = -(longint'(1) <<< (INTERNAL_SUM_WIDTH-1));
    localparam int     W_MAX   = (1 <<< (WEIGHT_WIDTH-1)) - 1;
    localparam int     W_MIN   = -(1 <<< (WEIGHT_WIDTH-1));
    localparam int     A_MAX   = (1 <<< (ACT_WIDTH-1)) - 1;
    localparam int     A_MIN   = -(1 <<< (ACT_WIDTH-1));

    // Full precision MAC result, used to check both the value and that it fits in INTERNAL_SUM_WIDTH
    longint mac_full;
    assign mac_full = longint'(weight_r) * longint'(west_i) + longint'(north_i);

    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);

    // ---------------------------------------------------------------- Assertions
    a_east_pass: assert property (1'b1 |=> east_o == $past(west_i))
        else `SVA_FAIL("PE east_o is not west_i delayed by one cycle")

    a_load_pass: assert property (load_weight_i |=> south_o == $past(north_i))
        else `SVA_FAIL("PE did not pass north_i to south_o while loading weights")

    a_mac: assert property (!load_weight_i |=> longint'(south_o) == $past(mac_full))
        else `SVA_FAIL("PE south_o != weight_r * west_i + north_i")

    a_no_overflow: assert property (!load_weight_i |-> (mac_full >= SUM_MIN && mac_full <= SUM_MAX))
        else `SVA_FAIL("PE MAC result overflows INTERNAL_SUM_WIDTH")

    a_weight_write: assert property (write_weight_i |=> weight_r == $past(north_i[WEIGHT_WIDTH-1:0]))
        else `SVA_FAIL("PE weight_r was not captured from north_i on write_weight_i")

    a_weight_hold: assert property (!write_weight_i |=> weight_r == $past(weight_r))
        else `SVA_FAIL("PE weight_r changed without write_weight_i")

    a_write_needs_load: assert property (write_weight_i |-> load_weight_i)
        else `SVA_FAIL("PE write_weight_i asserted without load_weight_i")

    a_known: assert property (!$isunknown({load_weight_i, write_weight_i, east_o, south_o, weight_r}))
        else `SVA_FAIL("PE control, output or weight is X/Z")

    // ---------------------------------------------------------------- Coverage
    c_weight_written: cover property (write_weight_i);

    // Sample every MAC cycle (not during weight loading)
    covergroup cg_mac @(posedge clk_i iff (rstn_i && !load_weight_i));
        option.per_instance = 1;
        cp_weight: coverpoint weight_r {
            bins min  = {W_MIN};
            bins neg  = {[W_MIN+1:-1]};
            bins zero = {0};
            bins pos  = {[1:W_MAX-1]};
            bins max  = {W_MAX};
        }
        cp_act: coverpoint west_i {
            bins min  = {A_MIN};
            bins neg  = {[A_MIN+1:-1]};
            bins zero = {0};
            bins pos  = {[1:A_MAX-1]};
            bins max  = {A_MAX};
        }
        x_weight_act: cross cp_weight, cp_act;
    endgroup

    cg_mac cg_mac_inst = new();

endmodule
