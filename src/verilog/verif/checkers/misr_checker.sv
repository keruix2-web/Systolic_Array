`include "mm_verif_defs.svh"

module misr_checker #(parameter NUM_BITS=64) (
    input logic clk_i, rstn_i, bypass_i, done_i, valid_i,
    input logic [NUM_BITS-1:0] seed_i, data_i, misr_data_o,
    input logic misr_valid_o
);
    logic past_valid;
    always_ff @(posedge clk_i or negedge rstn_i)
        if (!rstn_i) past_valid <= 0;
        else past_valid <= 1;
    function automatic logic [NUM_BITS-1:0] compress(
        logic [NUM_BITS-1:0] signature, logic [NUM_BITS-1:0] data);
        return {signature[NUM_BITS-2:0], signature[62]^signature[61]^signature[60]^signature[51]} ^ data;
    endfunction
    always @(posedge clk_i) begin
        if (!rstn_i) begin
            a_seed_reset: assert #0 (misr_data_o === seed_i && misr_valid_o === 1'b0)
                else `SVA_FAIL("reset must load seed and clear valid")
        end
    end
    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);
    a_valid: assert property (past_valid |-> misr_valid_o == $past(bypass_i ? valid_i : done_i))
        else `SVA_FAIL("MISR valid mismatch")
    a_passthrough: assert property (valid_i && bypass_i |=> misr_data_o == $past(data_i))
        else `SVA_FAIL("monitor registered external data mismatch")
    a_compress: assert property (valid_i && !bypass_i && !done_i |=>
        misr_data_o == compress($past(misr_data_o), $past(data_i)))
        else `SVA_FAIL("MISR signature update mismatch")
    a_hold: assert property (!valid_i || (!bypass_i && done_i) |=> $stable(misr_data_o))
        else `SVA_FAIL("MISR changed without valid data or after done")
    c_compress: cover property (valid_i && !bypass_i && !done_i);
    c_done: cover property (!bypass_i && done_i ##1 misr_valid_o);
endmodule
