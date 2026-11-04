/******************************************************************************
 Module Name : debug_obs
 Description :
	Observes 
*******************************************************************************/

module debug_obs
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

        // Inputs from the controller
        input state_struct                      state_i,
        input logic [$clog2(MAX_ROW+1)-1:0]     rd_count_i,
        input logic [$clog2(MAX_ROW+1)-1:0]     wr_count_i,
        input logic [$clog2(MAX_ROW/Tk)-1:0]    k_count_i,
        input logic [$clog2(MAX_COL/Tn)-1:0]    n_count_i,
        input logic                             start_pulse_i,
        input logic                             last_k_i,

        // Top level control signals
        input logic                             done_i,
        input logic                             ext_en_i,
        input logic                             load_weight_i,
        input logic                             act_valid_i,
        input logic                             psum_valid_i,
        input logic                             psum_valid_delayed_i,
        input logic                             ext_valid_i,

        // Signals from PE and saturate modules
        input logic [WIDTH-1:0]                 weight_xor_i,
        input logic                             sat16_i,
        input logic                             sat8_i,
        input logic                             sat_ext_i,

        output logic [7:0]                      obs_o
    );

    // The first scan bit is for fp_en and the rest are for the debug select
    logic fp_en_w;
    logic [2:0] obs_sel_w;
    assign fp_en_w = extra_config_i[0];
    assign obs_sel_w[2:0] = extra_config_i[3:1];

    // 8 bit counters of the number of inputs and outputs (wraps around on overflow)
    logic [7:0] output_count_r, input_count_r;

    // Sticky flags to indicate each debug event
    logic psum_16_sat_flag_r, output_8_sat_flag_r, weight_load_flag_r, input_valid_flag_r, output_valid_flag_r;
    logic start_seen_flag_r;

    // Update the input and output count on each clock cycle
    always_ff @(posedge clk_i) begin
        // Reset on a new start pulse or rst
        if(!rstn_i || start_pulse_i) begin
            output_count_r <= '0;
            input_count_r <= '0;
        end else begin
            if(psum_valid_i)    output_count_r <= output_count_r + 1'b1;
            if(act_valid_i)     input_count_r <= input_count_r + 1'b1;
        end
    end

    // Set the sticky flags on their events
    always_ff @(posedge clk_i) begin
        // Reset most sticky flags on rst or start_pulse
        if(!rstn_i || start_pulse_i) begin
            psum_16_sat_flag_r <= 1'b0;
            output_8_sat_flag_r <= 1'b0;
            weight_load_flag_r <= 1'b0;
            input_valid_flag_r <= 1'b0;
            output_valid_flag_r <= 1'b0;
        end else begin
            if(psum_valid_delayed_i && !last_k_i && sat16_i)                                psum_16_sat_flag_r <= 1'b1;
            if((psum_valid_delayed_i && last_k_i && sat8_i) || (ext_valid_i && sat_ext_i))  output_8_sat_flag_r <= 1'b1;
            if(load_weight_i)                                                               weight_load_flag_r <= 1'b1;
            if(act_valid_i)                                                                 input_valid_flag_r <= 1'b1;
            if(psum_valid_i)                                                                output_valid_flag_r <= 1'b1;
        end
    end

    // Set the start seen flag seperately because this flag should not reset on start_pulse
    always_ff @(posedge clk_i) begin
        if(!rstn_i)                 start_seen_flag_r <= 1'b0;
        else if(start_pulse_i)      start_seen_flag_r <= 1'b1;
    end

    // Create a MUX to choose the debug to output based on the scan in bits
    always_comb begin
        case(obs_sel_w)
            3'b000: begin
                // Output flags (the design's status)
                obs_o = {1'b0, start_seen_flag_r, fp_en_w, ext_en_i, done_i, state_i};
            end
            3'b001: begin
                // Output the tile counters, 4 bits each
                // The counters are $clog2(MAX/Tn or Tk) bits, which is exactly 4 for a 4x4 array
                // For smaller arrays the size cast keeps the low 4 bits (the count wraps at 16),
                // and for larger arrays it zero extends
                obs_o = {4'(n_count_i), 4'(k_count_i)};
            end
            3'b010: begin
               // Output the read counter
                obs_o = {state_i == STREAM, rd_count_i};
            end
            3'b011: begin
                // Output the write counter
                obs_o = {last_k_i, wr_count_i};
            end
            3'b100: begin
                // Output the XOR of the weights
                obs_o = weight_xor_i;
            end
            3'b101: begin
                // Output the number of valid outputs seen
                obs_o = output_count_r;
            end
            3'b110: begin
                // Output the number of valid inputs seen
                obs_o = input_count_r;
            end
            3'b111: begin
                // Output the event flags
                // Use 3 0 bits as placeholders for FP flags
                obs_o = {output_valid_flag_r, input_valid_flag_r, weight_load_flag_r, 3'b000, output_8_sat_flag_r, psum_16_sat_flag_r};
            end
            default: begin
                obs_o = '0;
            end

        endcase
    end

endmodule