/******************************************************************************
 Module Name : systolic_array_checker
 Description :
     Assertions, a scoreboard and coverage for systolic_array. Bound to the
     systolic_array instance in mm_binds.sv.

     The scoreboard only uses the array's ports, independent of the PE
     internals:
       - Weight loading: on write_weight_i, array row r holds the weight_i
         row presented r cycles earlier (row 0 = the last row presented)
       - Streaming: every act_valid_i row a produces one psum_o row,
         psum_o[j] = sum_r W[r][j] * a[r] in full precision, exactly
         ARRAY_H + ARRAY_W - 1 cycles later with psum_valid_o high
       - Debug add-on: weight_xor_o is the XOR of every weight the model
         says the array holds
     Coverage:
       - Magnitude of every valid psum_o lane (in 8-bit range, beyond 8 bits,
         beyond 16 bits) to show the full-precision path is exercised
*******************************************************************************/

`include "mm_verif_defs.svh"

module systolic_array_checker
    #(
        parameter INPUT_WIDTH=8,
        parameter ARRAY_W=4,
        parameter ARRAY_H=4,
        parameter ACCUM_WIDTH=2*INPUT_WIDTH + $clog2(ARRAY_H)
    )
    (
        input logic                                 clk_i,
        input logic                                 rstn_i,
        input logic                                 load_weight_i,
        input logic                                 write_weight_i,
        input logic [ARRAY_W-1:0][INPUT_WIDTH-1:0]  weight_i,
        input logic                                 act_valid_i,
        input logic [ARRAY_H-1:0][INPUT_WIDTH-1:0]  act_i,
        input logic [ARRAY_W-1:0][ACCUM_WIDTH-1:0]  psum_o,
        input logic                                 psum_valid_o,
        input logic [INPUT_WIDTH-1:0]               weight_xor_o
    );

    localparam int LATENCY = ARRAY_H + ARRAY_W - 1;

    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);

    // ---------------------------------------------------------------- Assertions
    a_valid_latency: assert property (act_valid_i |-> ##LATENCY psum_valid_o)
        else `SVA_FAIL("psum_valid_o did not follow act_valid_i after ARRAY_H + ARRAY_W - 1 cycles")

    a_no_extra_valid: assert property (!act_valid_i |-> ##LATENCY !psum_valid_o)
        else `SVA_FAIL("psum_valid_o asserted without a matching act_valid_i")

    a_write_needs_load: assert property (write_weight_i |-> load_weight_i)
        else `SVA_FAIL("write_weight_i asserted without load_weight_i")

    a_load_xor_stream: assert property (!(load_weight_i && act_valid_i))
        else `SVA_FAIL("load_weight_i and act_valid_i asserted together")

    a_act_known: assert property (act_valid_i |-> !$isunknown(act_i))
        else `SVA_FAIL("act_i is X/Z while act_valid_i is high")

    a_weight_known: assert property (load_weight_i |-> !$isunknown(weight_i))
        else `SVA_FAIL("weight_i is X/Z while load_weight_i is high")

    a_psum_known: assert property (psum_valid_o |-> !$isunknown(psum_o))
        else `SVA_FAIL("psum_o is X/Z while psum_valid_o is high")

    a_ctrl_known: assert property (!$isunknown({load_weight_i, write_weight_i, act_valid_i, psum_valid_o}))
        else `SVA_FAIL("systolic_array control signal is X/Z")

    // ---------------------------------------------------------------- Scoreboard
    // Packed so the queue stores copies (one 64-bit slot per lane)
    typedef logic [ARRAY_W-1:0][63:0] psum_row_t;

    logic [ARRAY_W-1:0][INPUT_WIDTH-1:0]    weight_hist [ARRAY_H];  // weight_hist[r] = weight_i from r+1 cycles ago
    logic [ARRAY_H-1:0]                     load_hist;              // load_hist[r]   = load_weight_i from r+1 cycles ago
    logic [ARRAY_W-1:0][INPUT_WIDTH-1:0]    weight_model [ARRAY_H]; // weights the array should hold
    psum_row_t                              expected_q [$];

    function automatic psum_row_t expected_row(logic [ARRAY_H-1:0][INPUT_WIDTH-1:0] act);
        psum_row_t row;
        for (int j = 0; j < ARRAY_W; j++) begin
            longint sum = 0;
            for (int r = 0; r < ARRAY_H; r++)
                sum += longint'($signed(weight_model[r][j])) * longint'($signed(act[r]));
            row[j] = sum;
        end
        return row;
    endfunction

    // Plain always (not always_ff): this block increments mm_verif_pkg::sva_errors, which every
    // other checker also writes, and VCS forbids an always_ff variable from having other drivers
    always @(posedge clk_i) begin
        if (!rstn_i) begin
            load_hist <= '0;
            expected_q.delete();
            for (int r = 0; r < ARRAY_H; r++) begin
                weight_hist[r]  <= '0;
                weight_model[r] <= '0;
            end
        end else begin
            load_hist <= {load_hist[ARRAY_H-2:0], load_weight_i};
            for (int r = ARRAY_H-1; r > 0; r--) weight_hist[r] <= weight_hist[r-1];
            weight_hist[0] <= weight_i;

            // Row 0 takes the current weight row, row r the one presented r cycles ago
            if (write_weight_i) begin
                a_full_load: assert (&load_hist[ARRAY_H-2:0])
                    else `SVA_FAIL("write_weight_i without ARRAY_H consecutive load_weight_i cycles")
                weight_model[0] <= weight_i;
                for (int r = 1; r < ARRAY_H; r++) weight_model[r] <= weight_hist[r-1];
            end

            if (act_valid_i) expected_q.push_back(expected_row(act_i));

            if (psum_valid_o) begin
                if (expected_q.size() == 0) begin
                    `SVA_FAIL("systolic_array produced a psum row with no matching activation row")
                end else begin
                    psum_row_t exp_row;
                    exp_row = expected_q.pop_front();
                    for (int j = 0; j < ARRAY_W; j++) begin
                        automatic longint got = longint'($signed(psum_o[j]));
                        automatic longint exp = longint'($signed(exp_row[j]));
                        if (got != exp) begin
                            mm_verif_pkg::sva_errors++;
                            $error("[SCB] %m: psum_o[%0d] = %0d, expected %0d", j, got, exp);
                        end
                    end
                end
            end
        end
    end

    // Debug add-on checksum, from the weight model instead of the PE registers
    logic [INPUT_WIDTH-1:0] weight_xor_model;
    always_comb begin
        weight_xor_model = '0;
        for (int r = 0; r < ARRAY_H; r++)
            for (int j = 0; j < ARRAY_W; j++)
                weight_xor_model ^= weight_model[r][j];
    end

    a_weight_xor: assert property (weight_xor_o == weight_xor_model)
        else `SVA_FAIL("weight_xor_o is not the XOR of the weights loaded into the array")

    // ---------------------------------------------------------------- Coverage
    covergroup cg_psum with function sample(int psum, int lane);
        cp_psum: coverpoint psum {
            bins neg_beyond_16b = {[$:-32769]};
            bins neg_beyond_8b  = {[-32768:-129]};
            bins in_8b          = {[-128:127]};
            bins pos_beyond_8b  = {[128:32767]};
            bins pos_beyond_16b = {[32768:$]};
        }
        cp_lane: coverpoint lane {
            bins lane[] = {[0:ARRAY_W-1]};
        }
        x_psum_lane: cross cp_psum, cp_lane;
    endgroup

    cg_psum cg_psum_inst = new();

    always @(posedge clk_i) begin
        if (rstn_i && psum_valid_o && !$isunknown(psum_o))
            for (int j = 0; j < ARRAY_W; j++) cg_psum_inst.sample(int'($signed(psum_o[j])), j);
    end

    c_weight_load:  cover property (load_weight_i[*ARRAY_H] ##0 write_weight_i);
    c_load_then_stream: cover property (write_weight_i ##1 act_valid_i);

endmodule
