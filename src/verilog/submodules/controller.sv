/******************************************************************************
 Module Name : controller
 Description :
	This controller drives the signals that control the systolic array PEs
    and the memory reads and writes. It coordinates timing so that tiled
    matrix multiplication is complete for the given input data configuration. 
*******************************************************************************/

module controller_9
    import matrix_mult_pkg::*;          // To access data config structure to get the input row size
    import controller_fsm_pkg::*;       // Structure where fsm states are delcared
    #(
        parameter Tn=4,                 // Array width
        parameter Tk=4,                 // Array height = rows of weights loaded per tile
        parameter W_SIZE=1024,
        parameter I_SIZE=1024,
        parameter O_SIZE=1024
    )
    (
        input logic                             clk_i,
        input logic                             rstn_i,
        input logic                             start_i,
        input data_config_struct                data_config_i,
        output logic                            done_o,

        // Weight memory (read only)
        output logic                            wb_mem_cenb_o,
        output logic                            wb_mem_wenb_o,
        output logic [$clog2(W_SIZE)-1:0]       wb_mem_addr_o,

        // input activation memory (read only)
        output logic                            ib_mem_cenb_o,
        output logic                            ib_mem_wenb_o,
        output logic [$clog2(I_SIZE)-1:0]       ib_mem_addr_o,

        // Output memory write port (data is driven in matrix_mult)
        output logic                            ob_mem_cenb_W_o,
        output logic                            ob_mem_wenb_W_o,
        output logic [$clog2(O_SIZE)-1:0]       ob_mem_addr_W_o,

        // Output memory read port (For partial sum accumulation, the output memory must be read)
        output logic                            ob_mem_cenb_R_o,
        output logic                            ob_mem_wenb_R_o,
        output logic [$clog2(O_SIZE)-1:0]       ob_mem_addr_R_o,

        // Systolic array control
        output logic                            load_weight_o,
        output logic                            write_weight_o,
        output logic                            act_valid_o,
        output logic                            psum_valid_delayed_o,
        output logic                            first_k_o,
        output logic                            last_k_o,
        input logic                             psum_valid_i,

        // Expose some internal state for the debug add-on
        output state_struct                     state_o,
        output logic [$clog2(MAX_ROW+1)-1:0]    rd_count_o,
        output logic [$clog2(MAX_ROW+1)-1:0]    wr_count_o,
        output logic [$clog2(MAX_ROW/Tk)-1:0]   k_count_o,
        output logic [$clog2(MAX_COL/Tn)-1:0]   n_count_o,
        output logic                            start_pulse_o

    );

    // Variables to keep track of FSM state
    state_struct state_r, next_state_w;

    // Create a counter to count the number of reads issued and number of output rows written
    // This will keep track of our progress through matrix multiplication
    logic [$clog2(MAX_ROW+1)-1:0] rd_count_r, wr_count_r;

    // Hold the final tile index in the k and n direction
    // The maximum number of possible tiles is 64 (maximum matrix size) divided by array width/height
    logic [$clog2(MAX_ROW/Tk)-1:0] k_last_w;
    logic [$clog2(MAX_COL/Tn)-1:0] n_last_w;

    // The next tile's weights are loaded while the last tile is still draining, so the read side
    // (weight/activation reads, driven by the FSM) and the write side (partial sum reads and writes,
    // driven by psum_valid_i) can be working on different tiles. Each side keeps its own tile counters.

    // Read side counters to track progress through tiling
    logic [$clog2(MAX_ROW/Tk)-1:0] k_count_r;
    logic [$clog2(MAX_COL/Tn)-1:0] n_count_r;

    // Write side counters (the tile whose outputs are currently being written)
    logic [$clog2(MAX_ROW/Tk)-1:0] wr_k_count_r;
    logic [$clog2(MAX_COL/Tn)-1:0] wr_n_count_r;

    // Create variables to keep track of the memory offsets due to tiling
    // Using these counters that are incremented on a cyclical basis is cheaper than multiplying to calculate memory address
    // The weight and input offsets belong to the read side, the partial sum offset to the write side
    logic [$clog2(W_SIZE)-1:0] w_tile_offset_r;
    logic [$clog2(I_SIZE)-1:0] i_tile_offset_r;
    logic [$clog2(O_SIZE)-1:0] p_tile_offset_r;

    // Create combinational signals to indicate when a tile has finished on each side
    // rd_tile_done_w: the last input row of the tile is read (last STREAM cycle)
    // wr_tile_done_w: the last output row of the tile is written
    logic rd_tile_done_w, wr_tile_done_w;

    // Create combinational signals to detect when we have reached the final n or k tile on each side
    logic last_k_w, last_n_w;
    logic wr_last_k_w, wr_last_n_w;

    // Create a signal to detect when the first k tile is being written
    logic wr_first_k_w;

    // Create a wire to hold the address of the psum output
    logic [$clog2(O_SIZE)-1:0] psum_addr_w;

    // Create registers to hold the delayed psum valid and address for write delayed one signal from read
    logic psum_valid_delayed_r;
    logic [$clog2(O_SIZE)-1:0] psum_addr_delayed_r;

    // Detect a rising edge of the start signal by keeping track of the previous start signal
    logic start_previous_r, start_pulse_w;

    // Coarse clock enable for the counters and tile offsets. In IDLE and DONE they only need the
    // first cycle (to clear for the next run), so they are gated for the rest of the wait.
    // state_r, start_previous_r and idle_done_q_r stay ungated so a start edge can wake the controller
    logic idle_done_w, idle_done_q_r, ctrl_en_w;

    always_ff @(posedge clk_i) 
        // Setting start_previous to start_i on reset prevents a bug where, if start is held high during
        // reset, when the reset ends, a phantom rising edge is captured
        if(!rstn_i)     start_previous_r <= start_i;
        else            start_previous_r <= start_i;

    assign start_pulse_w = start_i & ~start_previous_r;

    // Calculate the number of k/n tiles using the data config input
    // K is equal to the number of weight rows and N is equal to the number of weight columns
    // Subtract by 1 to convert this to the final tile index (so it fits in the register)
    assign k_last_w = (data_config_i.w_rows / Tk) - 1'b1;
    assign n_last_w = (data_config_i.w_cols / Tn) - 1'b1;

    // Set the last_k_w and last_n_w flag based on if our counters indicate we are on the last tile in that dimension
    assign last_k_w = k_last_w == k_count_r;
    assign last_n_w = n_last_w == n_count_r;
    assign wr_last_k_w = k_last_w == wr_k_count_r;
    assign wr_last_n_w = n_last_w == wr_n_count_r;

    // Set the first k flag based on if the write side k counter is at 0
    assign wr_first_k_w = wr_k_count_r == 0;

    // first_k_o and last_k_o select the accumulate input and the 16/8-bit output in matrix_mult,
    // so they follow the tile being written, not the tile being read
    assign first_k_o = wr_first_k_w;
    assign last_k_o = wr_last_k_w;

    // A tile is done reading on its last STREAM cycle
    assign rd_tile_done_w = (state_r == STREAM) && (rd_count_r == data_config_i.i_rows-1);
    // A tile is done writing on the cycle after its last psum_valid_i, which is the cycle of the last
    // delayed write. The write side counters change after this cycle, so the last row still uses them
    assign wr_tile_done_w = (wr_count_r == data_config_i.i_rows);

    // Always statement to register state changes
    always_ff @(posedge clk_i)
        if(!rstn_i)     state_r <= IDLE;
        else            state_r <= next_state_w;

    // Remember if last cycle was IDLE or DONE so the counters are enabled on the first waiting cycle only
    // Every counter is 0 after that cycle, and the only update a start edge causes (rd_count_r clearing)
    // is already a no-op, so gating them for the rest of IDLE/DONE does not change their values
    assign idle_done_w = (state_r == IDLE) || (state_r == DONE);
    always_ff @(posedge clk_i)
        if(!rstn_i)     idle_done_q_r <= 1'b0;
        else            idle_done_q_r <= idle_done_w;
    assign ctrl_en_w = !idle_done_w || !idle_done_q_r;

    // Always statement for next state combinational logic and calculation work
    always_comb begin
        // By default, make the next state statex to make debugging easier
        next_state_w = STATEX;

        case(state_r)
            IDLE: begin
                // Begin only on a positive edge of start
                // Start with weight loading
                if(start_pulse_w)                                   next_state_w = LOAD_WEIGHT;
                else                                                next_state_w = IDLE;
            end
            LOAD_WEIGHT: begin
                // Continue loading weights until every row of the systolic array has been loaded
                if(rd_count_r == Tk-1)                              next_state_w = STREAM;
                else                                                next_state_w = LOAD_WEIGHT;
            end
            STREAM: begin
                // Once we have read all the rows in the input matrix, this tile is done reading
                if(rd_tile_done_w) begin
                    // After the last tile, wait for its outputs to be written
                    if(last_k_w && last_n_w)                        next_state_w = FINAL_DRAIN;
                    // Otherwise wait for the top row to finish before loading the next weights.
                    // With a single column there is nothing to wait for
                    else if(Tn > 1)                                 next_state_w = GAP;
                    else                                            next_state_w = LOAD_WEIGHT;
                end else                                            next_state_w = STREAM;
            end
            GAP: begin
                // Wait Tn-1 cycles (rd_count_r 0 to Tn-2) so the next weights enter row 0 right after
                // PE(0,Tn-1) does its last MAC. Each weight then reaches row i the cycle after row i
                // finishes, and every PE has finished by the time write_weight_o rises
                if(rd_count_r == Tn-2)                              next_state_w = LOAD_WEIGHT;
                else                                                next_state_w = GAP;
            end
            FINAL_DRAIN: begin
                // Once the last row of the last tile has been written, we have finished
                if(wr_tile_done_w && wr_last_k_w && wr_last_n_w)    next_state_w = DONE;
                else                                                next_state_w = FINAL_DRAIN;
            end
            DONE: begin
                // Keep the done signal high (stay in done) until we start again or the system is reset
                if(start_pulse_w)                                   next_state_w = LOAD_WEIGHT;
                else                                                next_state_w = DONE;
            end
            default:                                                next_state_w = STATEX;
        endcase
    end

    // Update counters
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            rd_count_r <= '0;
            wr_count_r <= '0;
            n_count_r <= '0;
            k_count_r <= '0;
            wr_n_count_r <= '0;
            wr_k_count_r <= '0;
        end else if(ctrl_en_w) begin
            // The read counter restarts every time the state changes
            if(next_state_w != state_r)                             rd_count_r <= '0;
            // In weight loading and streaming, a read occurs every cycle. In GAP it counts the wait cycles
            else if(state_r == LOAD_WEIGHT || state_r == STREAM || state_r == GAP)
                                                                    rd_count_r <= rd_count_r + 1'b1;

            // The write counter clears after the last row of each tile is written. It can't clear in
            // LOAD_WEIGHT because the last tile may still be writing while the next tile loads weights
            if(wr_tile_done_w)                                      wr_count_r <= '0;
            // A write occurs every time the psum valid signal is high
            else if(psum_valid_i)                                   wr_count_r <= wr_count_r + 1'b1;

            // Reset the n and k counters when a new tiling operation begins
            if(state_r == IDLE || state_r == DONE) begin
                                                                    n_count_r <= '0;
                                                                    k_count_r <= '0;
                                                                    wr_n_count_r <= '0;
                                                                    wr_k_count_r <= '0;
            end else begin
                // Only increment the read side tile counts when a tile has finished reading
                if(rd_tile_done_w) begin
                    // If this is the last k, reset k and increment n
                    if(last_k_w) begin
                                                                    k_count_r <= '0;
                                                                    n_count_r <= n_count_r + 1'b1;
                    end else                                        k_count_r <= k_count_r + 1'b1;
                end

                // Same for the write side when a tile has finished writing
                if(wr_tile_done_w) begin
                    if(wr_last_k_w) begin
                                                                    wr_k_count_r <= '0;
                                                                    wr_n_count_r <= wr_n_count_r + 1'b1;
                    end else                                        wr_k_count_r <= wr_k_count_r + 1'b1;
                end
            end
        end
    end

    // Update memory offsets for tiling
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            w_tile_offset_r <= '0;
            i_tile_offset_r <= '0;
            p_tile_offset_r <= '0;
        end else if(ctrl_en_w) begin
            // Every time the matrix multiplication operation restarts, reset the memory offsets to 0
            if(state_r == IDLE || state_r == DONE) begin
                w_tile_offset_r <= '0;
                i_tile_offset_r <= '0;
                p_tile_offset_r <= '0;
            end else begin
                // The read offsets only update when a tile finishes reading
                if(rd_tile_done_w) begin
                    // Increment the weight offset every tile by the number of weights rows used last tile (Tk)
                    w_tile_offset_r <= w_tile_offset_r + Tk;
                    // On the last k, reset the i offset
                    if(last_k_w)    i_tile_offset_r <= '0;
                    // Otherwise, increment by the number of input rows read for the last tile
                    else            i_tile_offset_r <= i_tile_offset_r + data_config_i.i_rows;
                end

                // The output (p) offset only updates when a tile finishes writing, on the last k
                // Increment by the number of output rows written for the last tile
                if(wr_tile_done_w && wr_last_k_w)
                                    p_tile_offset_r <= p_tile_offset_r + data_config_i.i_rows;
            end
        end
    end

    // Create memory read requests on the same cycle as the state
    always_comb begin
        // By default, turn off read (1 is off because the signals are inverse)
        wb_mem_cenb_o = 1'b1;
        wb_mem_wenb_o = 1'b1;
        wb_mem_addr_o = '0;

        ib_mem_cenb_o = 1'b1;
        ib_mem_wenb_o = 1'b1;
        ib_mem_addr_o = '0;

        case(state_r)
            LOAD_WEIGHT: begin
                // Enable read of the memory address of the next weight (access in reverse order
                // so the weights are in the right position on the last cycle)
                wb_mem_cenb_o = 1'b0;
                wb_mem_addr_o = data_config_i.w_offset + w_tile_offset_r + (Tk-1 - rd_count_r);
            end
            STREAM: begin
                // Enable the read of the memory address of the next activation row
                ib_mem_cenb_o = 1'b0;
                ib_mem_addr_o = data_config_i.i_offset + i_tile_offset_r + rd_count_r;
            end
            // For all other states, use the default behavior
            default: ;
        endcase
    end

    // Create the array control signals one cycle after the read to match memory latency
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            load_weight_o   <= 1'b0;
            write_weight_o  <= 1'b0;
            act_valid_o     <= 1'b0;
        end else begin
            // The load weight signal tells the PE to pass the weights to the next PE
            load_weight_o   <= (state_r == LOAD_WEIGHT);
            // On the last weight load cycle, write all of the weights to the PEs
            write_weight_o  <= (state_r == LOAD_WEIGHT) && (rd_count_r == Tk - 1);
            // The activation inputs are valid during the stream stage
            act_valid_o     <= (state_r == STREAM);
        end
    end

    // Constantly drive the output read write enable bar port high because we don't write to the read port
    // Read the partial sum address if this is not the first k tile
    assign ob_mem_wenb_R_o = 1'b1;
    assign ob_mem_cenb_R_o = ~(psum_valid_i & ~wr_first_k_w);
    // Save the write address to a wire that can also be used for the write output
    assign psum_addr_w = data_config_i.psum_offset + p_tile_offset_r + wr_count_r;
    assign ob_mem_addr_R_o = psum_addr_w;

    // Create the output write signals a clock cycle after the read signals
    // The address only matters on a write, so only capture it with a valid partial sum (clock gated)
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            psum_valid_delayed_r <= 1'b0;
            psum_addr_delayed_r <= '0;
        end else begin
            psum_valid_delayed_r <= psum_valid_i;
            if(psum_valid_i)    psum_addr_delayed_r <= psum_addr_w;
        end
    end
    assign ob_mem_cenb_W_o = ~psum_valid_delayed_r;
    assign ob_mem_wenb_W_o = ~psum_valid_delayed_r;
    assign ob_mem_addr_W_o = psum_addr_delayed_r;
    assign psum_valid_delayed_o = psum_valid_delayed_r;

    // Raise the done signal high while we are waiting for a start edge (IDLE after reset, DONE after a run)
    // so done is high out of reset and stays high until the next start
    assign done_o = (state_r == IDLE) || (state_r == DONE);

    // Connect internal register values to outputs for debug add-on
    assign state_o = state_r;
    assign rd_count_o = rd_count_r;
    assign wr_count_o = wr_count_r;
    assign k_count_o = k_count_r;
    assign n_count_o = n_count_r;
    // Only report start edges while the controller is out of reset (start_pulse_w is combinational,
    // so it would still pulse in external/BiST mode where the controller is held in reset)
    assign start_pulse_o = start_pulse_w && rstn_i;
    
endmodule