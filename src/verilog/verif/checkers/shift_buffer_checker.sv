/******************************************************************************
 Module Name : shift_buffer_checker
 Description :
     Assertions for shift_buffer. Bound to every shift_buffer instance.

     BUFFER_LENGTH == 0 : data_o must equal data_i (a wire)
     BUFFER_LENGTH  > 0 : the buffer only shifts on cycles with en_i high (it is
                          clock gated otherwise). data_o must equal the data_i
                          sampled on the BUFFER_LENGTH-th most recent enabled
                          cycle, and must be 0 until BUFFER_LENGTH enabled
                          cycles have passed since reset
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
        input logic                     en_i,
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
            // Number of enabled clock edges since reset, saturating at BUFFER_LENGTH
            int unsigned edges_since_reset;

            // Inputs sampled on enabled edges, newest at the back. Once full, the front is the
            // value data_o should hold. It is copied to expected_o so the assertion uses a static variable
            logic [DATA_WIDTH-1:0] sampled_q [$];
            logic [DATA_WIDTH-1:0] expected_o;

            always @(posedge clk_i) begin
                if (!rstn_i) begin
                    edges_since_reset <= 0;
                    sampled_q.delete();
                    expected_o <= '0;
                end else if (en_i) begin
                    if (edges_since_reset < BUFFER_LENGTH) edges_since_reset <= edges_since_reset + 1;
                    sampled_q.push_back(data_i);
                    if (sampled_q.size() > BUFFER_LENGTH) void'(sampled_q.pop_front());
                    expected_o <= sampled_q[0];
                end
            end

            // disable iff is written on each property because VCS ignores a default disable iff
            // declared inside a generate block, which made these fire during reset
            default clocking cb @(posedge clk_i); endclocking

            a_delay: assert property (disable iff (!rstn_i) edges_since_reset >= BUFFER_LENGTH |-> data_o == expected_o)
                else `SVA_FAIL("shift_buffer output is not the input from BUFFER_LENGTH enabled cycles ago")

            a_filling_zero: assert property (disable iff (!rstn_i) edges_since_reset < BUFFER_LENGTH |-> data_o == '0)
                else `SVA_FAIL("shift_buffer output is not 0 before the buffer has filled after reset")

            a_known: assert property (disable iff (!rstn_i) !$isunknown({en_i, data_o}))
                else `SVA_FAIL("shift_buffer output or enable is X/Z")
        end
    endgenerate

endmodule
