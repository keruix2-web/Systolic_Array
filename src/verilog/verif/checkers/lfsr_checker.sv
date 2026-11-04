`include "mm_verif_defs.svh"

// The supplied course feedback polynomial uses zero-based taps 63,62,61,52.
module lfsr_checker #(parameter NUM_BITS=64) (
    input logic clk_i, rstn_i, bypass_i, en_i, valid_i,
    input logic [NUM_BITS-1:0] seed_i, stop_code_i, lfsr_data_o,
    input logic lfsr_valid_o, lfsr_done_o
);
    logic past_valid;
    always_ff @(posedge clk_i or negedge rstn_i)
        if (!rstn_i) past_valid <= 0;
        else past_valid <= 1;
    function automatic logic [NUM_BITS-1:0] advance(logic [NUM_BITS-1:0] value);
        return {value[NUM_BITS-2:0], value[63]^value[62]^value[61]^value[52]};
    endfunction
    always @(posedge clk_i) begin
        if (!rstn_i) begin
            a_seed_reset: assert #0 (lfsr_data_o === seed_i && lfsr_valid_o === 1'b0)
                else `SVA_FAIL("reset must load seed and clear valid")
        end
    end
    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);
    a_valid: assert property (past_valid |-> lfsr_valid_o ==
        $past(bypass_i ? valid_i : (valid_i && en_i)))
        else `SVA_FAIL("LFSR valid mismatch")
    a_passthrough: assert property (valid_i && bypass_i |=> lfsr_data_o == $past(seed_i))
        else `SVA_FAIL("LFSR registered external data mismatch")
    a_advance: assert property (valid_i && !bypass_i && en_i |=> lfsr_data_o == advance($past(lfsr_data_o)))
        else `SVA_FAIL("LFSR feedback/shift mismatch")
    a_hold: assert property (!valid_i || (!bypass_i && !en_i) |=> $stable(lfsr_data_o))
        else `SVA_FAIL("LFSR changed without enable")
    a_stop: assert property (lfsr_done_o == (lfsr_data_o == stop_code_i))
        else `SVA_FAIL("LFSR stop comparator mismatch")
    c_generated: cover property ((valid_i && !bypass_i && en_i)[*4]);
    c_stopped: cover property (lfsr_done_o);
endmodule
