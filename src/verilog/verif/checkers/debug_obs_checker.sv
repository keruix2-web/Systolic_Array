/******************************************************************************
 Module Name : debug_obs_checker
 Description :
     Reference model, assertions and coverage for the debug observation
     add-on. Bound to the debug_obs instance in mm_binds.sv, so it sees the
     same inputs as debug_obs and its output obs_o.

     The checker keeps its own counters and sticky flags, written from the
     page table in src/verilog/README.md, and builds the selected page from
     them. Checks:
       - obs_o equals the page picked by obs_sel (extra_config_i[3:1]) in
         every cycle and every mode. This is a deferred immediate assertion,
         so it also checks that a new obs_sel reaches obs_o without a clock
         edge (the page mux is not registered)
       - Counters and flags clear on reset and on a start edge; the
         start-seen flag clears only on reset
       - Saturation flags only set on a cycle the value is actually used:
         the delayed psum write in memory mode, ext_valid in external mode
       - fp_en (extra_config_i[0]) only shows up as the status page echo
     Coverage:
       - Every obs_sel value, in memory mode and in external mode
       - Every flag set, flags cleared by a start edge, both counters
         wrapping past 255
*******************************************************************************/

`include "mm_verif_defs.svh"

module debug_obs_checker
    import matrix_mult_pkg::*;
    import controller_fsm_pkg::*;
    #(
        parameter WIDTH=8,
        parameter Tn=4,
        parameter Tk=4
    )
    (
        input logic                             clk_i,
        input logic                             rstn_i,
        input logic [3:0]                       extra_config_i,

        input state_struct                      state_i,
        input logic [$clog2(MAX_ROW+1)-1:0]     rd_count_i,
        input logic [$clog2(MAX_ROW+1)-1:0]     wr_count_i,
        input logic [$clog2(MAX_ROW/Tk)-1:0]    k_count_i,
        input logic [$clog2(MAX_COL/Tn)-1:0]    n_count_i,
        input logic                             start_pulse_i,
        input logic                             last_k_i,

        input logic                             done_i,
        input logic                             ext_en_i,
        input logic                             load_weight_i,
        input logic                             act_valid_i,
        input logic                             psum_valid_i,
        input logic                             psum_valid_delayed_i,
        input logic                             ext_valid_i,

        input logic [WIDTH-1:0]                 weight_xor_i,
        input logic                             sat16_i,
        input logic                             sat8_i,
        input logic                             sat_ext_i,

        input logic [7:0]                       obs_o
    );

    logic       fp_en;
    logic [2:0] obs_sel;
    assign fp_en   = extra_config_i[0];
    assign obs_sel = extra_config_i[3:1];

    // ---------------------------------------------------------------- Reference model
    logic [7:0] ref_out_count, ref_in_count;
    logic       ref_sat16, ref_sat8, ref_weight_load, ref_in_seen, ref_out_seen, ref_start_seen;
    logic       seen_reset;     // the model only means something after the first reset

    initial seen_reset = 1'b0;

    // Plain always (not always_ff) because seen_reset also has an initial value
    always @(posedge clk_i) begin
        if (!rstn_i) seen_reset <= 1'b1;

        if (!rstn_i)                ref_start_seen <= 1'b0;
        else if (start_pulse_i)     ref_start_seen <= 1'b1;

        if (!rstn_i || start_pulse_i) begin
            ref_out_count   <= '0;
            ref_in_count    <= '0;
            ref_sat16       <= 1'b0;
            ref_sat8        <= 1'b0;
            ref_weight_load <= 1'b0;
            ref_in_seen     <= 1'b0;
            ref_out_seen    <= 1'b0;
        end else begin
            ref_out_count   <= ref_out_count + 8'(psum_valid_i);
            ref_in_count    <= ref_in_count  + 8'(act_valid_i);
            // Intermediate K tiles write the 16-bit value, the last K tile the 8-bit value
            ref_sat16       <= ref_sat16 | (psum_valid_delayed_i && !last_k_i && sat16_i);
            ref_sat8        <= ref_sat8  | (psum_valid_delayed_i &&  last_k_i && sat8_i)
                                         | (ext_valid_i && sat_ext_i);
            ref_weight_load <= ref_weight_load | load_weight_i;
            ref_in_seen     <= ref_in_seen     | act_valid_i;
            ref_out_seen    <= ref_out_seen    | psum_valid_i;
        end
    end

    // Expected page. Fields are sized to their slots (see the page table in the README)
    logic [7:0] expected;
    always_comb begin
        case (obs_sel)
            3'd0: expected = {1'b0, ref_start_seen, fp_en, ext_en_i, done_i, 3'(state_i)};
            3'd1: expected = {4'(n_count_i), 4'(k_count_i)};
            3'd2: expected = {state_i == STREAM, 7'(rd_count_i)};
            3'd3: expected = {last_k_i, 7'(wr_count_i)};
            3'd4: expected = 8'(weight_xor_i);
            3'd5: expected = ref_out_count;
            3'd6: expected = ref_in_count;
            3'd7: expected = {ref_out_seen, ref_in_seen, ref_weight_load, 3'b000, ref_sat8, ref_sat16};
            default: expected = 'x;
        endcase
    end

    // Explicit sensitivity (not always_comb) so the failure counter is not part of it
    always @(obs_o, expected, rstn_i, seen_reset, extra_config_i) begin
        if (rstn_i && seen_reset && !$isunknown(extra_config_i)) begin
            a_page: assert #0 (obs_o === expected)
                else `SVA_FAIL("debug_obs obs_o does not match the selected page")
        end
    end

    // ---------------------------------------------------------------- Coverage
    covergroup cg_page @(posedge clk_i iff (rstn_i && seen_reset));
        cp_sel_mem: coverpoint obs_sel iff (!ext_en_i) {
            bins page[] = {[0:7]};
        }
        cp_sel_ext: coverpoint obs_sel iff (ext_en_i) {
            bins page[] = {[0:7]};
        }
        cp_fp_en: coverpoint fp_en;
    endgroup

    covergroup cg_flags @(posedge clk_i iff (rstn_i && seen_reset));
        cp_sat16:       coverpoint ref_sat16        { bins set = {1}; }
        cp_sat8:        coverpoint ref_sat8         { bins set = {1}; }
        cp_weight_load: coverpoint ref_weight_load  { bins set = {1}; }
        cp_in_seen:     coverpoint ref_in_seen      { bins set = {1}; }
        cp_out_seen:    coverpoint ref_out_seen     { bins set = {1}; }
        cp_start_seen:  coverpoint ref_start_seen   { bins set = {1}; }
        cp_clear:       coverpoint (start_pulse_i && (ref_sat16 || ref_sat8 || ref_out_seen)) {
            bins cleared_by_start = {1};
        }
    endgroup

    cg_page  cg_page_inst  = new();
    cg_flags cg_flags_inst = new();

    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);

    c_out_count_wrap: cover property (ref_out_count == 8'hFF && psum_valid_i && !start_pulse_i);
    c_in_count_wrap:  cover property (ref_in_count  == 8'hFF && act_valid_i  && !start_pulse_i);
    c_ext_sat:        cover property (ext_valid_i && sat_ext_i);

endmodule
