/******************************************************************************
 Module Name : controller_checker
 Description :
     Assertions and coverage for the controller FSM. Bound to the controller
     instance in mm_binds.sv, so it can see state_r, start_pulse_w and
     wr_count_r.

     The checker keeps its own K/N tile indices (ref_k, ref_n: N outer loop,
     K inner loop) and computes the expected tile base addresses with
     multiplies, independent of the controller's offset registers.

     Checks:
       - start_pulse_w fires only on a true rising edge of start_i
       - Only legal FSM transitions occur
       - LOAD_WEIGHT lasts exactly Tk cycles, STREAM exactly i_rows cycles
       - DRAIN ends when the last row of the tile is written, then goes to
         LOAD_WEIGHT for the next tile or to DONE after the last tile
       - Weight rows are read Tk-1 down to 0, input rows 0 up to i_rows-1
         (relative to the tile base address), and only in their own state
       - Array controls line up with the 1-cycle memory read latency
       - first_k_o / last_k_o match the current K tile
       - Partial sums are read (R port) for every row except on the first K
         tile, and each row is written (W port) one cycle after psum_valid_i
         to the same address
     Coverage:
       - Every state and every legal transition
       - Reset arriving in every state
       - Number of input rows (i_rows) and K/N tiles per run
*******************************************************************************/

`include "mm_verif_defs.svh"

module controller_checker
    import matrix_mult_pkg::*;
    import controller_fsm_pkg::*;
    #(
        parameter Tn=4,
        parameter Tk=4,
        parameter W_SIZE=1024,
        parameter I_SIZE=1024,
        parameter O_SIZE=1024
    )
    (
        input logic                         clk_i,
        input logic                         rstn_i,
        input logic                         start_i,
        input data_config_struct            data_config_i,
        input logic                         done_o,

        input logic                         wb_mem_cenb_o,
        input logic                         wb_mem_wenb_o,
        input logic [$clog2(W_SIZE)-1:0]    wb_mem_addr_o,
        input logic                         ib_mem_cenb_o,
        input logic                         ib_mem_wenb_o,
        input logic [$clog2(I_SIZE)-1:0]    ib_mem_addr_o,
        input logic                         ob_mem_cenb_W_o,
        input logic                         ob_mem_wenb_W_o,
        input logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_W_o,
        input logic                         ob_mem_cenb_R_o,
        input logic                         ob_mem_wenb_R_o,
        input logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_R_o,

        input logic                         load_weight_o,
        input logic                         write_weight_o,
        input logic                         act_valid_o,
        input logic                         first_k_o,
        input logic                         last_k_o,
        input logic                         psum_valid_i,

        // Internal controller signals
        input state_struct                  state_r,
        input logic                         start_pulse_w,
        input logic [$clog2(MAX_ROW+1)-1:0] wr_count_r
    );

    localparam int W_AW = $clog2(W_SIZE);
    localparam int I_AW = $clog2(I_SIZE);
    localparam int O_AW = $clog2(O_SIZE);

    // Coverage bin edges for w_rows / w_cols (one, two, several, and the maximum number of tiles)
    localparam int K_TWO    = 2 * Tk;
    localparam int K_MID_LO = 3 * Tk;
    localparam int K_MID_HI = MAX_ROW - Tk;
    localparam int N_TWO    = 2 * Tn;
    localparam int N_MID_LO = 3 * Tn;
    localparam int N_MID_HI = MAX_COL - Tn;

    // ---------------------------------------------------------------- Reference tile model
    int unsigned k_tiles, n_tiles;      // tiles in each dimension for the current configuration
    int unsigned ref_k, ref_n;          // current tile (N outer loop, K inner loop)
    int unsigned psum_rd_idx;           // psum_valid_i rows seen in the current tile
    logic        tile_end;              // last row of the tile is written this cycle
    logic        ref_last_k, ref_last_n;
    logic        busy_state;

    assign k_tiles    = data_config_i.w_rows / Tk;
    assign n_tiles    = data_config_i.w_cols / Tn;
    assign ref_last_k = (ref_k == k_tiles - 1);
    assign ref_last_n = (ref_n == n_tiles - 1);
    assign tile_end   = (state_r == DRAIN) && (wr_count_r == data_config_i.i_rows);
    assign busy_state = state_r inside {LOAD_WEIGHT, STREAM, DRAIN};

    always_ff @(posedge clk_i) begin
        if (!rstn_i || !busy_state) begin
            ref_k <= 0;
            ref_n <= 0;
        end else if (tile_end) begin
            if (ref_last_k) begin
                ref_k <= 0;
                ref_n <= ref_n + 1;
            end else begin
                ref_k <= ref_k + 1;
            end
        end

        if (!rstn_i || state_r == LOAD_WEIGHT)  psum_rd_idx <= 0;
        else if (psum_valid_i)                  psum_rd_idx <= psum_rd_idx + 1;
    end

    // Expected base address of the current tile in each memory (words)
    int unsigned w_base, i_base, p_base;
    assign w_base = data_config_i.w_offset    + (ref_n * k_tiles + ref_k) * Tk;
    assign i_base = data_config_i.i_offset    + ref_k * data_config_i.i_rows;
    assign p_base = data_config_i.psum_offset + ref_n * data_config_i.i_rows;

    // Cycles spent in STREAM during the current visit
    int unsigned stream_cycles;
    always_ff @(posedge clk_i) begin
        if (!rstn_i || state_r != STREAM)   stream_cycles <= 0;
        else                                stream_cycles <= stream_cycles + 1;
    end

    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);

    // ---------------------------------------------------------------- Start edge detection
    a_start_edge: assert property (start_pulse_w == (start_i && !$past(start_i)))
        else `SVA_FAIL("start_pulse_w is not exactly the rising edge of start_i")

    // ---------------------------------------------------------------- FSM
    a_state_legal: assert property (!$isunknown(state_r) && state_r inside {IDLE, LOAD_WEIGHT, STREAM, DRAIN, DONE})
        else `SVA_FAIL("controller state_r is X or not a legal state")

    a_idle_start: assert property (state_r == IDLE && start_pulse_w |=> state_r == LOAD_WEIGHT)
        else `SVA_FAIL("IDLE did not move to LOAD_WEIGHT on a start edge")
    a_idle_hold: assert property (state_r == IDLE && !start_pulse_w |=> state_r == IDLE)
        else `SVA_FAIL("IDLE left without a start edge")

    a_load_len: assert property ($rose(state_r == LOAD_WEIGHT) |-> (state_r == LOAD_WEIGHT)[*Tk] ##1 state_r == STREAM)
        else `SVA_FAIL("LOAD_WEIGHT did not last exactly Tk cycles before STREAM")

    a_stream_next: assert property (state_r == STREAM |=> state_r inside {STREAM, DRAIN})
        else `SVA_FAIL("illegal transition out of STREAM")
    a_stream_len: assert property ($fell(state_r == STREAM) |-> stream_cycles == data_config_i.i_rows)
        else `SVA_FAIL("STREAM did not last exactly i_rows cycles")

    a_drain_next: assert property (state_r == DRAIN |=> state_r inside {DRAIN, LOAD_WEIGHT, DONE})
        else `SVA_FAIL("illegal transition out of DRAIN")
    a_drain_hold: assert property (state_r == DRAIN && !tile_end |=> state_r == DRAIN)
        else `SVA_FAIL("DRAIN ended before the last row of the tile was written")
    a_drain_next_tile: assert property (tile_end && !(ref_last_k && ref_last_n) |=> state_r == LOAD_WEIGHT)
        else `SVA_FAIL("DRAIN did not go to LOAD_WEIGHT for the next tile")
    a_drain_done: assert property (tile_end && ref_last_k && ref_last_n |=> state_r == DONE)
        else `SVA_FAIL("DRAIN did not go to DONE after the last tile")

    a_done_restart: assert property (state_r == DONE && start_pulse_w |=> state_r == LOAD_WEIGHT)
        else `SVA_FAIL("DONE did not restart on a start edge")
    a_done_hold: assert property (state_r == DONE && !start_pulse_w |=> state_r == DONE)
        else `SVA_FAIL("DONE left without a start edge")

    a_done_o: assert property (done_o == (state_r == DONE))
        else `SVA_FAIL("done_o does not match state_r == DONE")

    // ---------------------------------------------------------------- Memory reads
    a_mem_read_only: assert property (wb_mem_wenb_o && ib_mem_wenb_o)
        else `SVA_FAIL("controller drove a write to the input or weight memory")

    a_wb_read_window: assert property (!wb_mem_cenb_o == (state_r == LOAD_WEIGHT))
        else `SVA_FAIL("weight memory read outside of (or missing during) LOAD_WEIGHT")
    a_ib_read_window: assert property (!ib_mem_cenb_o == (state_r == STREAM))
        else `SVA_FAIL("input memory read outside of (or missing during) STREAM")

    a_wb_first_addr: assert property (state_r == LOAD_WEIGHT && $past(state_r) != LOAD_WEIGHT |-> wb_mem_addr_o == W_AW'(w_base + Tk - 1))
        else `SVA_FAIL("first weight read of a tile is not w_offset + (n*K/Tk + k)*Tk + Tk - 1")
    a_wb_addr_dec: assert property (state_r == LOAD_WEIGHT && $past(state_r == LOAD_WEIGHT) |-> wb_mem_addr_o == W_AW'($past(wb_mem_addr_o) - 1))
        else `SVA_FAIL("weight read addresses do not count down by 1")

    a_ib_first_addr: assert property ($rose(state_r == STREAM) |-> ib_mem_addr_o == I_AW'(i_base))
        else `SVA_FAIL("first input read of a tile is not i_offset + k*i_rows")
    a_ib_addr_inc: assert property (state_r == STREAM && $past(state_r == STREAM) |-> ib_mem_addr_o == I_AW'($past(ib_mem_addr_o) + 1))
        else `SVA_FAIL("input read addresses do not count up by 1")

    // ---------------------------------------------------------------- Array control (1 cycle after the read)
    a_load_weight_align: assert property (1'b1 |=> load_weight_o == $past(state_r == LOAD_WEIGHT))
        else `SVA_FAIL("load_weight_o is not LOAD_WEIGHT delayed by one cycle")
    a_act_valid_align: assert property (1'b1 |=> act_valid_o == $past(state_r == STREAM))
        else `SVA_FAIL("act_valid_o is not STREAM delayed by one cycle")
    a_write_weight_last: assert property ($fell(load_weight_o) |-> $past(write_weight_o))
        else `SVA_FAIL("write_weight_o was not asserted on the last weight load cycle")
    a_write_weight_pulse: assert property (write_weight_o |-> load_weight_o ##1 !write_weight_o)
        else `SVA_FAIL("write_weight_o is not a single pulse inside load_weight_o")

    // ---------------------------------------------------------------- Output writes
    a_psum_window: assert property (psum_valid_i |-> state_r inside {STREAM, DRAIN})
        else `SVA_FAIL("psum_valid_i outside of STREAM/DRAIN")
    a_ob_write_enable: assert property (ob_mem_cenb_W_o == ob_mem_wenb_W_o && ob_mem_cenb_W_o == !$past(psum_valid_i))
        else `SVA_FAIL("output write enables are not psum_valid_i delayed by one cycle")
    a_ob_R_read_only: assert property (ob_mem_wenb_R_o)
        else `SVA_FAIL("controller drove a write through the output memory read (R) port")
    a_ob_R_enable: assert property (!ob_mem_cenb_R_o == (psum_valid_i && ref_k != 0))
        else `SVA_FAIL("partial sum read enable is not psum_valid_i on a K tile after the first")
    a_ob_R_addr: assert property (!ob_mem_cenb_R_o |-> ob_mem_addr_R_o == O_AW'(p_base + psum_rd_idx))
        else `SVA_FAIL("partial sum read address is not psum_offset + n*i_rows + row")
    a_ob_RW_same_addr: assert property (psum_valid_i |=> !ob_mem_cenb_W_o && ob_mem_addr_W_o == O_AW'($past(p_base + psum_rd_idx)))
        else `SVA_FAIL("output row was not written one cycle after psum_valid_i to the address that was read")
    // wr_count_r keeps its last value in DONE until the next LOAD_WEIGHT, so only check it in a tile
    a_wr_count_bound: assert property (state_r inside {STREAM, DRAIN} |-> wr_count_r <= data_config_i.i_rows)
        else `SVA_FAIL("wr_count_r exceeded i_rows")
    a_tile_end_write: assert property (tile_end |-> !ob_mem_cenb_W_o && psum_rd_idx == data_config_i.i_rows)
        else `SVA_FAIL("DRAIN ended on a cycle that was not the last row write of the tile")

    // first_k_o / last_k_o select the accumulate input and the 16/8-bit output in matrix_mult
    a_first_k: assert property (busy_state |-> first_k_o == (ref_k == 0))
        else `SVA_FAIL("first_k_o does not match the current K tile")
    a_last_k: assert property (busy_state |-> last_k_o == ref_last_k)
        else `SVA_FAIL("last_k_o does not match the current K tile")

    // ---------------------------------------------------------------- Coverage
    covergroup cg_fsm @(posedge clk_i iff rstn_i);
        cp_state: coverpoint state_r {
            bins idle   = {IDLE};
            bins load   = {LOAD_WEIGHT};
            bins stream = {STREAM};
            bins drain  = {DRAIN};
            bins done   = {DONE};
        }
        cp_trans: coverpoint state_r {
            bins idle_hold      = (IDLE => IDLE);
            bins idle_to_load   = (IDLE => LOAD_WEIGHT);
            bins load_hold      = (LOAD_WEIGHT => LOAD_WEIGHT);
            bins load_to_stream = (LOAD_WEIGHT => STREAM);
            bins stream_hold    = (STREAM => STREAM);
            bins stream_to_drain= (STREAM => DRAIN);
            bins drain_hold     = (DRAIN => DRAIN);
            bins drain_to_load  = (DRAIN => LOAD_WEIGHT);
            bins drain_to_done  = (DRAIN => DONE);
            bins done_hold      = (DONE => DONE);
            bins done_to_load   = (DONE => LOAD_WEIGHT);
            bins full_run       = (IDLE => LOAD_WEIGHT [* Tk] => STREAM);
        }
    endgroup

    // Sampled on the first reset cycle, before state_r returns to IDLE
    covergroup cg_reset @(posedge clk_i iff !rstn_i);
        cp_reset_in: coverpoint state_r {
            bins idle   = {IDLE};
            bins load   = {LOAD_WEIGHT};
            bins stream = {STREAM};
            bins drain  = {DRAIN};
            bins done   = {DONE};
        }
    endgroup

    // Sampled when a run starts
    covergroup cg_config @(posedge clk_i iff (rstn_i && start_pulse_w));
        cp_i_rows: coverpoint data_config_i.i_rows {
            bins one_tile   = {4};
            bins two_tiles  = {8};
            bins mid        = {[12:60]};
            bins max_rows   = {MAX_ROW};
        }
        cp_k_tiles: coverpoint data_config_i.w_rows {
            bins one   = {Tk};
            bins two   = {K_TWO};
            bins mid   = {[K_MID_LO:K_MID_HI]};
            bins max   = {MAX_ROW};
        }
        cp_n_tiles: coverpoint data_config_i.w_cols {
            bins one   = {Tn};
            bins two   = {N_TWO};
            bins mid   = {[N_MID_LO:N_MID_HI]};
            bins max   = {MAX_COL};
        }
        cp_from: coverpoint state_r {
            bins from_idle = {IDLE};
            bins from_done = {DONE};
        }
    endgroup

    cg_fsm    cg_fsm_inst    = new();
    cg_reset  cg_reset_inst  = new();
    cg_config cg_config_inst = new();

endmodule
