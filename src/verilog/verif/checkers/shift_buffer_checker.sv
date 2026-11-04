/******************************************************************************
 Module Name : shift_buffer_checker
 Description :
     Assertions for shift_buffer. Bound to every shift_buffer instance.

     BUFFER_LENGTH == 0 : data_o must equal data_i (a wire)
     BUFFER_LENGTH  > 0 : data_o must equal data_i from exactly BUFFER_LENGTH
                          cycles ago once the buffer has filled after reset,
                          and must be 0 while it is still filling
*******************************************************************************/

`include "mm_verif_defs.svh"

module shift_buffer_checker
    #(
        parameter DATA_WIDTH=8,
        parameter BUFFER_LENGTH=4
    )
    (
        input logic                     clk_i,
        input logic                     rstn_i,
        input logic [DATA_WIDTH-1:0]    data_i,
        input logic [DATA_WIDTH-1:0]    data_o
    );

    generate
        if (BUFFER_LENGTH == 0) begin : g_passthrough
            always @(data_i, data_o) begin
                a_passthrough: assert #0 (data_o === data_i)
                    else `SVA_FAIL("zero length shift_buffer output does not equal its input")
            end

        end else begin : g_shift
            // Number of clock edges since reset, saturating at BUFFER_LENGTH
            int unsigned edges_since_reset;

            always_ff @(posedge clk_i) begin
                if (!rstn_i)                                edges_since_reset <= 0;
                else if (edges_since_reset < BUFFER_LENGTH) edges_since_reset <= edges_since_reset + 1;
            end

            // disable iff is written on each property because VCS ignores a default disable iff
            // declared inside a generate block, which made these fire during reset
            default clocking cb @(posedge clk_i); endclocking

            a_delay: assert property (disable iff (!rstn_i) edges_since_reset >= BUFFER_LENGTH |-> data_o == $past(data_i, BUFFER_LENGTH))
                else `SVA_FAIL("shift_buffer output is not the input delayed by BUFFER_LENGTH")

            a_filling_zero: assert property (disable iff (!rstn_i) edges_since_reset < BUFFER_LENGTH |-> data_o == '0)
                else `SVA_FAIL("shift_buffer output is not 0 before the buffer has filled after reset")

            a_known: assert property (disable iff (!rstn_i) !$isunknown(data_o))
                else `SVA_FAIL("shift_buffer output is X/Z")
        end
    endgenerate

endmodule
