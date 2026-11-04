/******************************************************************************
 Module Name : matrix_mult_checker
 Description :
     Port-level (black box) assertions and coverage for matrix_mult in memory
     mode with tiling across K and N. Bound to matrix_mult in mm_binds.sv.
     Only array_psum_added_w and last_k_w are internal, and only for coverage.

     With KT = w_rows/Tk and NT = w_cols/Tn tiles, a run does NT*KT tiles
     (N outer loop, K inner loop). Each tile reads Tk weight words and i_rows
     activation words and writes i_rows output words. Output word r of N
     strip n is at psum_offset + n*i_rows + r, and it is written once per K
     tile (16-bit partial sums, then the final 8-bit value on the last K tile).

     Checks:
       - The input and weight memories are only read, the output R port only
         reads and the W port only writes
       - No memory activity before a start edge or after done_o
       - A run starts only on a rising edge of start_i (not a level, and not
         start_i already high when reset is released)
       - done_o rises within a latency bound for the configured shape, only
         after every tile is read and written, and stays high until the next
         start edge
       - Reads and writes stay inside the windows set by data_config_i offsets
       - Output words are written in tile order (N strip, then K tile, then row)
       - Every final (last K tile) output lane holds a sign-extended 8-bit value
     Coverage:
       - Saturation of every final output lane (in range, exact boundaries, saturated)
       - 16-bit partial sum saturation between K tiles
       - Start handshake corner cases (held high, restart from DONE, offsets, tiled runs)
*******************************************************************************/

`include "mm_verif_defs.svh"

module matrix_mult_checker
    import matrix_mult_pkg::*;
    #(
        parameter WIDTH=8,
        parameter ACCUM_WIDTH=16,
        parameter ARRAY_ACCUM_WIDTH=18,
        parameter Tm=4,
        parameter Tn=4,
        parameter Tk=4,
        parameter W_SIZE=1024,
        parameter I_SIZE=1024,
        parameter O_SIZE=1024
    )
    (
        input logic                             clk_i,
        input logic                             rstn_i,
        input logic                             start_i,
        input logic                             done_o,
        input data_config_struct                data_config_i,
        input logic                             ext_en_i,
        input logic                             ext_valid_o,

        input logic                             ob_mem_cenb_R_o,
        input logic                             ob_mem_wenb_R_o,
        input logic [$clog2(O_SIZE)-1:0]        ob_mem_addr_R_o,
        input logic                             ob_mem_cenb_W_o,
        input logic                             ob_mem_wenb_W_o,
        input logic [$clog2(O_SIZE)-1:0]        ob_mem_addr_W_o,
        input logic [Tn-1:0][ACCUM_WIDTH-1:0]   ob_mem_data_W_o,

        input logic                             ib_mem_cenb_o,
        input logic                             ib_mem_wenb_o,
        input logic [$clog2(I_SIZE)-1:0]        ib_mem_addr_o,
        input logic                             wb_mem_cenb_o,
        input logic                             wb_mem_wenb_o,
        input logic [$clog2(W_SIZE)-1:0]        wb_mem_addr_o,

        // Internal matrix_mult signals (coverage only)
        input logic [Tn-1:0][ARRAY_ACCUM_WIDTH:0] array_psum_added_w,
        input logic                             last_k_w
    );

    // ---------------------------------------------------------------- Reference state
    // Real rising edge of start_i. start_q is not reset, so start_i held high through
    // reset is not treated as an edge.
    logic start_q;
    logic start_rise;
    always_ff @(posedge clk_i) start_q <= start_i;
    assign start_rise = start_i && !start_q;

    // Busy start edges are ignored by the DUT and must not reset this model.
    // busy: a run has started and done_o has not been seen yet
    logic        busy;
    int unsigned n_writes, n_ob_reads, n_ib_reads, n_wb_reads, busy_cycles;

    logic ob_write, ob_read, ib_read, wb_read;
    assign ob_write = !ob_mem_cenb_W_o && !ob_mem_wenb_W_o;
    assign ob_read  = !ob_mem_cenb_R_o && ob_mem_wenb_R_o;
    assign ib_read  = !ib_mem_cenb_o && ib_mem_wenb_o;
    assign wb_read  = !wb_mem_cenb_o && wb_mem_wenb_o;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            busy        <= 1'b0;
            n_writes    <= 0;
            n_ob_reads  <= 0;
            n_ib_reads  <= 0;
            n_wb_reads  <= 0;
            busy_cycles <= 0;
        end else if (start_rise && (!busy || done_o)) begin
            busy        <= 1'b1;
            n_writes    <= 0;
            n_ob_reads  <= 0;
            n_ib_reads  <= 0;
            n_wb_reads  <= 0;
            busy_cycles <= 0;
        end else begin
            if (done_o)   busy <= 1'b0;
            if (busy && !done_o) busy_cycles <= busy_cycles + 1;
            if (ob_write) n_writes   <= n_writes + 1;
            if (ob_read)  n_ob_reads <= n_ob_reads + 1;
            if (ib_read)  n_ib_reads <= n_ib_reads + 1;
            if (wb_read)  n_wb_reads <= n_wb_reads + 1;
        end
    end

    // Shape of the current run
    int unsigned m_rows, k_tiles, n_tiles, tiles;
    assign m_rows  = data_config_i.i_rows;
    assign k_tiles = data_config_i.w_rows / Tk;
    assign n_tiles = data_config_i.w_cols / Tn;
    assign tiles   = k_tiles * n_tiles;

    // Each tile is LOAD_WEIGHT (Tk) + STREAM (i_rows) + DRAIN (array latency + write, under Tm + Tn + 4)
    int unsigned max_latency;
    assign max_latency = tiles * (Tk + m_rows + Tm + Tn + 4) + 8;

    // Output write number w goes to tile w / i_rows (N outer, K inner), row w % i_rows
    function automatic int unsigned expected_write_addr(int unsigned w);
        int unsigned tile = w / m_rows;
        return data_config_i.psum_offset + (tile / k_tiles) * m_rows + (w % m_rows);
    endfunction

    function automatic bit write_is_last_k(int unsigned w);
        return ((w / m_rows) % k_tiles) == k_tiles - 1;
    endfunction

    // True when addr is in [base, base + len) without wrapping
    function automatic bit in_window(int addr, int base, int len);
        return (addr >= base) && (addr < base + len);
    endfunction

    // True when every 16-bit lane is the sign extension of its low WIDTH bits
    function automatic bit lanes_sign_extended(logic [Tn-1:0][ACCUM_WIDTH-1:0] data);
        for (int j = 0; j < Tn; j++)
            if (data[j][ACCUM_WIDTH-1:WIDTH-1] != {(ACCUM_WIDTH-WIDTH+1){data[j][WIDTH-1]}}) return 1'b0;
        return 1'b1;
    endfunction

    default clocking cb @(posedge clk_i); endclocking
    default disable iff (!rstn_i);

    // ---------------------------------------------------------------- Memory port protocol
    a_ib_read_only: assert property (ib_mem_wenb_o)
        else `SVA_FAIL("matrix_mult wrote to the input memory")
    a_wb_read_only: assert property (wb_mem_wenb_o)
        else `SVA_FAIL("matrix_mult wrote to the weight memory")
    a_ob_R_read_only: assert property (!ob_mem_cenb_R_o |-> ob_mem_wenb_R_o)
        else `SVA_FAIL("matrix_mult wrote through the output memory read (R) port")
    a_ob_W_write_only: assert property (!ob_mem_cenb_W_o |-> !ob_mem_wenb_W_o)
        else `SVA_FAIL("matrix_mult read through the output memory write (W) port")

    a_ctrl_known: assert property (!$isunknown({done_o, ib_mem_cenb_o, ib_mem_wenb_o, wb_mem_cenb_o, wb_mem_wenb_o,
                                                ob_mem_cenb_R_o, ob_mem_wenb_R_o, ob_mem_cenb_W_o, ob_mem_wenb_W_o}))
        else `SVA_FAIL("matrix_mult done_o or memory enable is X/Z")
    a_ib_addr_known: assert property (!ib_mem_cenb_o |-> !$isunknown(ib_mem_addr_o))
        else `SVA_FAIL("input memory address is X/Z during a read")
    a_wb_addr_known: assert property (!wb_mem_cenb_o |-> !$isunknown(wb_mem_addr_o))
        else `SVA_FAIL("weight memory address is X/Z during a read")
    a_ob_write_known: assert property (ob_write |-> !$isunknown({ob_mem_addr_W_o, ob_mem_data_W_o}))
        else `SVA_FAIL("output memory address or data is X/Z during a write")

    // ---------------------------------------------------------------- Start / done handshake
    a_quiet_when_idle: assert property ((!busy || done_o) |-> ib_mem_cenb_o && wb_mem_cenb_o && ob_mem_cenb_W_o && ob_mem_cenb_R_o)
        else `SVA_FAIL("memory access before a start edge or after done_o")

    a_start_ack: assert property (start_rise && !busy |-> ##[1:2] (!wb_mem_cenb_o || !ib_mem_cenb_o))
        else `SVA_FAIL("computation did not begin within 2 cycles of the start_i rising edge")

    a_done_latency: assert property (busy && !done_o |-> busy_cycles <= max_latency)
        else `SVA_FAIL("done_o did not rise within the latency bound for this shape")

    a_done_hold: assert property (done_o && !start_rise |=> done_o)
        else `SVA_FAIL("done_o dropped before the next start edge")

    a_done_clears_on_start: assert property (done_o && start_rise |=> !done_o)
        else `SVA_FAIL("done_o stayed high after a new start edge")

    a_done_needs_run: assert property ($rose(done_o) |-> busy)
        else `SVA_FAIL("done_o rose without a start edge")

    // Every tile reads Tk weight words and i_rows activation words and writes i_rows output words.
    // Partial sums are read back on every K tile after the first.
    a_done_counts: assert property ($rose(done_o) |-> n_writes   == tiles * m_rows
                                                   && n_ib_reads == tiles * m_rows
                                                   && n_wb_reads == tiles * Tk
                                                   && n_ob_reads == (k_tiles - 1) * n_tiles * m_rows)
        else `SVA_FAIL("done_o rose before every tile was read and written exactly once")

    a_no_ext_valid: assert property (!ext_en_i |-> !ext_valid_o)
        else `SVA_FAIL("ext_valid_o asserted outside of external mode")

    // ---------------------------------------------------------------- Address windows and output data
    a_ib_window: assert property (ib_read |-> in_window(ib_mem_addr_o, data_config_i.i_offset, k_tiles * m_rows))
        else `SVA_FAIL("input memory read outside [i_offset, i_offset + i_rows*K/Tk)")
    a_wb_window: assert property (wb_read |-> in_window(wb_mem_addr_o, data_config_i.w_offset, n_tiles * data_config_i.w_rows))
        else `SVA_FAIL("weight memory read outside [w_offset, w_offset + K*N/Tn)")
    a_ob_window: assert property (ob_write |-> in_window(ob_mem_addr_W_o, data_config_i.psum_offset, n_tiles * m_rows))
        else `SVA_FAIL("output memory write outside [psum_offset, psum_offset + i_rows*N/Tn)")
    a_ob_R_window: assert property (ob_read |-> in_window(ob_mem_addr_R_o, data_config_i.psum_offset, n_tiles * m_rows))
        else `SVA_FAIL("partial sum read outside [psum_offset, psum_offset + i_rows*N/Tn)")

    // Output words are written in tile order: N strip, then K tile, then row
    a_ob_in_order: assert property (ob_write |-> ob_mem_addr_W_o == $clog2(O_SIZE)'(expected_write_addr(n_writes)))
        else `SVA_FAIL("output words are not written in tile order (N strip, K tile, row)")

    // Only the last K tile writes final 8-bit values; earlier tiles write 16-bit partial sums
    a_ob_sign_ext: assert property (ob_write && write_is_last_k(n_writes) |-> lanes_sign_extended(ob_mem_data_W_o))
        else `SVA_FAIL("final output lane is not a sign-extended 8-bit value")

    // ---------------------------------------------------------------- Coverage
    localparam int OUT_MAX = (1 <<< (WIDTH-1)) - 1;
    localparam int OUT_MIN = -(1 <<< (WIDTH-1));

    localparam int PSUM_MAX = (1 <<< (ACCUM_WIDTH-1)) - 1;
    localparam int PSUM_MIN = -(1 <<< (ACCUM_WIDTH-1));

    // Final outputs: value before the 8-bit saturation, and the 8-bit result
    covergroup cg_output with function sample(int psum, int out, int lane);
        cp_psum: coverpoint psum {
            bins sat_low     = {[$:OUT_MIN-2]};
            bins min_minus_1 = {OUT_MIN-1};
            bins min         = {OUT_MIN};
            bins in_range    = {[OUT_MIN+1:OUT_MAX-1]};
            bins max         = {OUT_MAX};
            bins max_plus_1  = {OUT_MAX+1};
            bins sat_high    = {[OUT_MAX+2:$]};
        }
        cp_out: coverpoint out {
            bins min  = {OUT_MIN};
            bins neg  = {[OUT_MIN+1:-1]};
            bins zero = {0};
            bins pos  = {[1:OUT_MAX-1]};
            bins max  = {OUT_MAX};
        }
        cp_lane: coverpoint lane {
            bins lane[] = {[0:Tn-1]};
        }
        x_psum_lane: cross cp_psum, cp_lane;
        x_out_lane:  cross cp_out, cp_lane;
    endgroup

    // Partial sums written between K tiles: value before the 16-bit saturation
    covergroup cg_psum16 with function sample(int psum, int lane);
        cp_psum: coverpoint psum {
            bins sat_low  = {[$:PSUM_MIN-1]};
            bins min      = {PSUM_MIN};
            bins in_range = {[PSUM_MIN+1:PSUM_MAX-1]};
            bins max      = {PSUM_MAX};
            bins sat_high = {[PSUM_MAX+1:$]};
        }
        cp_lane: coverpoint lane {
            bins lane[] = {[0:Tn-1]};
        }
    endgroup

    cg_output cg_output_inst = new();
    cg_psum16 cg_psum16_inst = new();

    always @(posedge clk_i) begin
        if (rstn_i && ob_write && !$isunknown({array_psum_added_w, ob_mem_data_W_o, last_k_w}))
            for (int j = 0; j < Tn; j++)
                if (last_k_w)
                    cg_output_inst.sample(int'($signed(array_psum_added_w[j])), int'($signed(ob_mem_data_W_o[j][WIDTH-1:0])), j);
                else
                    cg_psum16_inst.sample(int'($signed(array_psum_added_w[j])), j);
    end

    c_start_pulse:        cover property (start_rise ##1 !start_i);
    c_start_held_to_done: cover property (start_rise ##1 start_i[*1:$] ##0 $rose(done_o));
    c_restart_from_done:  cover property (done_o && start_rise);
    c_done_held_long:     cover property ($rose(done_o) ##0 done_o[*50]);
    c_nonzero_offsets:    cover property (start_rise && data_config_i.i_offset != 0 && data_config_i.w_offset != 0
                                          && data_config_i.psum_offset != 0);
    c_full_stream:        cover property (start_rise && data_config_i.i_rows == MAX_ROW ##[1:$] $rose(done_o));
    c_tiled_k_and_n:      cover property (start_rise && data_config_i.w_rows > Tk && data_config_i.w_cols > Tn ##[1:$] $rose(done_o));
    c_max_shape:          cover property (start_rise && data_config_i.i_rows == MAX_ROW && data_config_i.w_rows == MAX_ROW
                                          && data_config_i.w_cols == MAX_COL ##[1:$] $rose(done_o));

endmodule

