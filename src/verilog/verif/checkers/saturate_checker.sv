/******************************************************************************
 Module Name : saturate_checker
 Description :
     Assertions for the combinational saturate module. Bound to every
     saturate instance.

     data_o must equal data_i clamped to the signed OUTPUT_WIDTH range, and
     sat_o (debug add-on) must be high exactly when the input was clamped.
     Saturation coverage is collected in matrix_mult_checker, which has a
     clock to sample on.
*******************************************************************************/

`include "mm_verif_defs.svh"

module saturate_checker
    #(
        parameter   INPUT_WIDTH=18,
        parameter   OUTPUT_WIDTH=16
    )
    (
        input logic signed [INPUT_WIDTH-1:0]    data_i,
        input logic signed [OUTPUT_WIDTH-1:0]   data_o,
        input logic                             sat_o
    );

    localparam longint OUT_MAX = (longint'(1) <<< (OUTPUT_WIDTH-1)) - 1;
    localparam longint OUT_MIN = -(longint'(1) <<< (OUTPUT_WIDTH-1));

    initial begin
        a_widths: assert (INPUT_WIDTH >= OUTPUT_WIDTH)
            else `SVA_FAIL("saturate INPUT_WIDTH must be at least OUTPUT_WIDTH")
    end

    longint expected;

    always_comb begin
        if (longint'(data_i) > OUT_MAX)         expected = OUT_MAX;
        else if (longint'(data_i) < OUT_MIN)    expected = OUT_MIN;
        else                                    expected = longint'(data_i);
    end

    // Explicit sensitivity (not always_comb) so the failure counter is not part of it
    always @(data_i, data_o, sat_o, expected) begin
        if (!$isunknown(data_i)) begin
            a_clamp: assert #0 (longint'(data_o) == expected)
                else `SVA_FAIL("saturate output is not the input clamped to OUTPUT_WIDTH")
            a_sat_flag: assert #0 (sat_o == (expected != longint'(data_i)))
                else `SVA_FAIL("saturate sat_o does not match whether the input was clamped")
        end
    end

endmodule
