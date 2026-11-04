/******************************************************************************
 Module Name : systolic_array
 Description :
	This controller drives the signals that control the systolic array PEs
    and the memory reads and writes. It coordinates timing so that tiled
    matrix multiplication is complete for the given input data configuration. 
*******************************************************************************/

module controller
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

    // Create counters to track progress through tiling
    logic [$clog2(MAX_ROW/Tk)-1:0] k_count_r;
    logic [$clog2(MAX_COL/Tn)-1:0] n_count_r;

    // Create variables to keep track of the memory offsets due to tiling
    // Using these counters that are incremented on a cyclical basis is cheaper than multiplying to calculate memory address
    logic [$clog2(W_SIZE)-1:0] w_tile_offset_r;
    logic [$clog2(I_SIZE)-1:0] i_tile_offset_r;
    logic [$clog2(O_SIZE)-1:0] p_tile_offset_r;

    // Create a combinational signal to indicate when a tile has finished
    logic tile_done_w;

    // Create combinational signals to detect when we have reached the final n or k tile
    logic last_k_w, last_n_w;

    // Create a signal to detect when the first k tile is being written
    logic first_k_w;

    // Create a wire to hold the address of the psum output
    logic [$clog2(O_SIZE)-1:0] psum_addr_w;

    // Create registers to hold the delayed psum valid and address for write delayed one signal from read
    logic psum_valid_delayed_r;
    logic [$clog2(O_SIZE)-1:0] psum_addr_delayed_r;

    // Detect a rising edge of the start signal by keeping track of the previous start signal
    logic start_previous_r, start_pulse_w;

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

    // Set the first_k_w flag based on if the k counter is at 0
    assign first_k_w = k_count_r == 0;

    // Assign the output signals based on first and last k internal registers
    assign first_k_o = first_k_w;
    assign last_k_o = last_k_w;

    // Always statement to register state changes
    always_ff @(posedge clk_i)
        if(!rstn_i)     state_r <= IDLE;
        else            state_r <= next_state_w;

    // Always statement for next state combinational logic and calculation work
    always_comb begin
        // By default, make the next state statex to make debugging easier
        next_state_w = STATEX;

        // By default, set the tile done signal to 0
        tile_done_w = 1'b0;

        case(state_r)
            IDLE: begin
                // Begin only on a positive edge of start
                // Start with weight loading
                if(start_pulse_w)                           next_state_w = LOAD_WEIGHT;
                else                                        next_state_w = IDLE;
            end
            LOAD_WEIGHT: begin
                // Continue loading weights until every row of the systolic array has been loaded
                if(rd_count_r == Tk-1)                      next_state_w = STREAM;
                else                                        next_state_w = LOAD_WEIGHT;
            end
            STREAM: begin
                // Once we have read all the rows in the input matrix, we will start generating output
                if(rd_count_r == data_config_i.i_rows-1)    next_state_w = DRAIN;
                else                                        next_state_w = STREAM;
            end
            DRAIN: begin
                // Once we have written the same number of rows as in the activation matrix, we are done with this tile
                // Delay one cycle past this because accumulation takes 2 cycles (read partial sum memory & accumulate/write back)
                if(wr_count_r == data_config_i.i_rows) begin
                    // If this was the last tile in both tiling dimensions, we have finished
                    if(last_k_w && last_n_w)                    next_state_w = DONE;
                    // Otherwise we need to continue tiling by loading new weights
                    else                                    next_state_w = LOAD_WEIGHT;
                    // Indicate we have finished with a tile so the tile counters can be updated
                    tile_done_w = 1'b1;
                end else                                    next_state_w = DRAIN;

            end
            DONE: begin
                // Keep the done signal high (stay in done) until we start again or the system is reset
                if(start_pulse_w)                           next_state_w = LOAD_WEIGHT;
                else                                        next_state_w = DONE;
            end
            default:                                        next_state_w = STATEX;
        endcase
    end

    // Update counters
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            rd_count_r <= '0;
            wr_count_r <= '0;
            n_count_r <= '0;
            k_count_r <= '0;
        end else begin
            // The read counter restarts every time the state changes
            if(next_state_w != state_r)                             rd_count_r <= '0;
            // In weight loading and streaming, a read occurs every cycle
            else if(state_r == LOAD_WEIGHT || state_r == STREAM)    rd_count_r <= rd_count_r + 1'b1;

            // The write counter clears between each matrix multiplication tile run (which begins with weight loading)
            if(state_r == LOAD_WEIGHT)                              wr_count_r <= '0;
            // A write occurs every time the psum valid signal is high
            else if(psum_valid_i)                                   wr_count_r <= wr_count_r + 1'b1;

            // Reset the n and k counters when a new tiling operation begins
            if(state_r == IDLE || state_r == DONE) begin
                                                                    n_count_r <= '0;
                                                                    k_count_r <= '0;
            // Only increment tile counts when a tile has finished
            end else if(tile_done_w) begin
                // If this is the last k, reset k and increment n
                if(last_k_w) begin
                                                                    k_count_r <= '0;
                                                                    n_count_r <= n_count_r + 1'b1;

                end else                                            k_count_r <= k_count_r + 1'b1;
            end
        end
    end

    // Update memory offsets for tiling
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            w_tile_offset_r <= '0;
            i_tile_offset_r <= '0;
            p_tile_offset_r <= '0;
        end else begin
            // Every time the matrix multiplication operation restarts, reset the memory offsets to 0
            if(state_r == IDLE || state_r == DONE) begin
                w_tile_offset_r <= '0;
                i_tile_offset_r <= '0;
                p_tile_offset_r <= '0;
            // Otherwise, only update when a tile finishes
            end else if(tile_done_w) begin
                // Increment the weight offset every tile by the number of weights rows used last tile (Tk)
                w_tile_offset_r <= w_tile_offset_r + Tk;
                // On the last k, reset the i offset and increment the output (p) offset
                if(last_k_w)  begin
                    i_tile_offset_r <= '0;
                    // Increment by the number of output rows written for the last tile
                    p_tile_offset_r <= p_tile_offset_r + data_config_i.i_rows;
                // Otherwise, increment by the number of input rows read for the last tile
                end else    i_tile_offset_r <= i_tile_offset_r + data_config_i.i_rows;
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
            // The load weight signal tells the PE to pas the weights to the next PE
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
    assign ob_mem_cenb_R_o = ~(psum_valid_i & ~first_k_w);
    // Save the write address to a wire that can also be used for the write output
    assign psum_addr_w = data_config_i.psum_offset + p_tile_offset_r + wr_count_r;
    assign ob_mem_addr_R_o = psum_addr_w;

    // Create the output write signals a clock cycle after the read signals
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            psum_valid_delayed_r <= 1'b0;
            psum_addr_delayed_r <= '0;
        end else begin
            psum_valid_delayed_r <= psum_valid_i;
            psum_addr_delayed_r <= psum_addr_w;
        end
    end
    assign ob_mem_cenb_W_o = ~psum_valid_delayed_r;
    assign ob_mem_wenb_W_o = ~psum_valid_delayed_r;
    assign ob_mem_addr_W_o = psum_addr_delayed_r;
    assign psum_valid_delayed_o = psum_valid_delayed_r;

    // Raise the done signal high while we are in the done state
    assign done_o = (state_r == DONE);

    // Connect internal register values to outputs for debug add-on
    assign state_o = state_r;
    assign rd_count_o = rd_count_r;
    assign wr_count_o = wr_count_r;
    assign k_count_o = k_count_r;
    assign n_count_o = n_count_r;
    assign start_pulse_o = start_pulse_w;
    
endmodule