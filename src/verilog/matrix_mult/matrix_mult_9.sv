import matrix_mult_pkg::*;
import controller_fsm_pkg::*;

module matrix_mult_9 #(
    parameter WIDTH=8,
    parameter ACCUM_WIDTH=16,
    parameter ARRAY_ACCUM_WIDTH=18,
    parameter Tm=4,
    parameter Tn=4,
    parameter Tk=4,
    parameter M=64,
    parameter N=64,
    parameter K=64,
    parameter W_SIZE=1024,
    parameter I_SIZE=1024,
    parameter O_SIZE=1024
    ) (
    input  logic                          clk_i,            
    input  logic                          rstn_i,           

    //for top-level reasons, please use the *_R_* ports as the read port to psum/output memory
    output  logic                         ob_mem_cenb_R_o,    
    output  logic                         ob_mem_wenb_R_o,    
    output  logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_R_o,    
    output  logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_o,        //read port, so output data port goes unused
    input   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_i,    

    //for top-level reasons, please use the *_W_* ports as the write port to psum/output memory
    output  logic                         ob_mem_cenb_W_o,    
    output  logic                         ob_mem_wenb_W_o,    
    output  logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_W_o,    
    output  logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_o,    
    input   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_i,        //write port, so input data port goes unused

    output  logic                         ib_mem_cenb_o,    
    output  logic                         ib_mem_wenb_o,    
    output  logic [$clog2(I_SIZE)-1:0]    ib_mem_addr_o,    
    input   logic [Tm-1:0][WIDTH-1:0]     ib_mem_data_i,    

    output  logic                         wb_mem_cenb_o,    
    output  logic                         wb_mem_wenb_o,    
    output  logic [$clog2(W_SIZE)-1:0]    wb_mem_addr_o,    
    input   logic [Tn-1:0][WIDTH-1:0]     wb_mem_data_i,

    input  logic                          ext_en_i,         
    input  external_inputs_struct         ext_inputs_i,     
    output logic [Tn-1:0][WIDTH-1:0]      ext_result_o,     
    output logic                          ext_valid_o,      
    
    input  logic                          start_i,          
    output logic                          done_o,           
    input  data_config_struct             data_config_i,
    output extra_output_bits_struct       extra_output_bits_o     
    );

    // Wires to connect controller and systolic array
    logic load_weight_w, write_weight_w, act_valid_w, psum_valid_w, psum_valid_delayed_w;
    logic first_k_w, last_k_w;

    // Wires to buffer and saturate partial sum output 
    logic [Tn-1:0][ARRAY_ACCUM_WIDTH-1:0] array_psum_sys_w;
    logic [Tn-1:0][ARRAY_ACCUM_WIDTH-1:0] array_psum_buff_w;
    logic [Tn-1:0][ARRAY_ACCUM_WIDTH:0] array_psum_added_w;

    // Create wires for each saturation precision
    logic [Tn-1:0][ACCUM_WIDTH-1:0] array_psum_sat_16_w;
    logic [Tn-1:0][WIDTH-1:0] array_psum_sat_8_w;

    // External and memory modes share the array, but not result latency.
    // Memory mode buffers a row for the psum read; external mode uses raw psum.
    logic mem_rstn, mem_done;
    logic mem_wb_cenb, mem_wb_wenb, mem_ib_cenb, mem_ib_wenb;
    logic mem_ob_R_cenb, mem_ob_R_wenb, mem_ob_W_cenb, mem_ob_W_wenb;
    logic [$clog2(W_SIZE)-1:0] mem_wb_addr;
    logic [$clog2(I_SIZE)-1:0] mem_ib_addr;
    logic [$clog2(O_SIZE)-1:0] mem_ob_R_addr, mem_ob_W_addr;
    logic ext_load_weight, ext_write_weight, ext_act_valid;
    logic load_weight, write_weight, act_valid;
    logic [Tn-1:0][WIDTH-1:0] array_weight, external_result;
    logic [Tk-1:0][WIDTH-1:0] array_activation;

    // Wires to receive debug signals from the controller, systolic array, and saturate modules
    state_struct controller_state_w;
    logic [$clog2(MAX_ROW+1)-1:0] rd_count_w, wr_count_w;
    logic [$clog2(MAX_ROW/Tk)-1:0] k_count_w;
    logic [$clog2(MAX_COL/Tn)-1:0] n_count_w;
    logic start_pulse_w;
    logic [WIDTH-1:0] weight_xor_w;
    logic [Tn-1:0] array_sat_16_psum_added_w, array_sat_8_psum_added_w, array_sat_psum_sys_w;
    logic sat_16_psum_added_or_w, sat_8_psum_added_or_w, sat_psum_sys_or_w;


    // Keep A's controller reset while external/BiST owns the array. Raw start_i
    // still reaches its edge detector, so a held start cannot become a new edge.
    assign mem_rstn = rstn_i && !ext_en_i;
    assign done_o = !ext_en_i && mem_done;
    assign wb_mem_cenb_o = ext_en_i ? 1'b1 : mem_wb_cenb;
    assign wb_mem_wenb_o = ext_en_i ? 1'b1 : mem_wb_wenb;
    assign wb_mem_addr_o = ext_en_i ? '0 : mem_wb_addr;
    assign ib_mem_cenb_o = ext_en_i ? 1'b1 : mem_ib_cenb;
    assign ib_mem_wenb_o = ext_en_i ? 1'b1 : mem_ib_wenb;
    assign ib_mem_addr_o = ext_en_i ? '0 : mem_ib_addr;
    assign ob_mem_cenb_R_o = ext_en_i ? 1'b1 : mem_ob_R_cenb;
    assign ob_mem_wenb_R_o = ext_en_i ? 1'b1 : mem_ob_R_wenb;
    assign ob_mem_addr_R_o = ext_en_i ? '0 : mem_ob_R_addr;
    assign ob_mem_cenb_W_o = ext_en_i ? 1'b1 : mem_ob_W_cenb;
    assign ob_mem_wenb_W_o = ext_en_i ? 1'b1 : mem_ob_W_wenb;
    assign ob_mem_addr_W_o = ext_en_i ? '0 : mem_ob_W_addr;

    external_controller #(.Tk(Tk)) u_external_controller (
        .clk_i, .rstn_i, .ext_en_i,
        .ext_weight_en_i(ext_inputs_i.ext_weight_en),
        .ext_valid_i(ext_inputs_i.ext_valid),
        .load_weight_o(ext_load_weight),
        .write_weight_o(ext_write_weight),
        .act_valid_o(ext_act_valid)
    );
    assign load_weight = ext_en_i ? ext_load_weight : load_weight_w;
    assign write_weight = ext_en_i ? ext_write_weight : write_weight_w;
    assign act_valid = ext_en_i ? ext_act_valid : act_valid_w;
    assign array_weight = ext_en_i ? ext_inputs_i.ext_weight : wb_mem_data_i;
    assign array_activation = ext_en_i ? ext_inputs_i.ext_input : ib_mem_data_i;

    // Instantiate the controller
    controller
    #(
        .Tn         (Tn),
        .Tk         (Tk),
        .W_SIZE     (W_SIZE),
        .I_SIZE     (I_SIZE),
        .O_SIZE     (O_SIZE)
    ) u_controller (
        .clk_i, .rstn_i(mem_rstn), .start_i, .data_config_i,
        .done_o(mem_done),
        .wb_mem_cenb_o(mem_wb_cenb), .wb_mem_wenb_o(mem_wb_wenb),
        .wb_mem_addr_o(mem_wb_addr),
        .ib_mem_cenb_o(mem_ib_cenb), .ib_mem_wenb_o(mem_ib_wenb),
        .ib_mem_addr_o(mem_ib_addr),
        .ob_mem_cenb_W_o(mem_ob_W_cenb), .ob_mem_wenb_W_o(mem_ob_W_wenb),
        .ob_mem_addr_W_o(mem_ob_W_addr),
        .ob_mem_cenb_R_o(mem_ob_R_cenb), .ob_mem_wenb_R_o(mem_ob_R_wenb),
        .ob_mem_addr_R_o(mem_ob_R_addr),

        .load_weight_o          (load_weight_w),
        .write_weight_o         (write_weight_w),
        .act_valid_o            (act_valid_w),
        .psum_valid_delayed_o   (psum_valid_delayed_w),
        .first_k_o              (first_k_w),
        .last_k_o               (last_k_w),
        .psum_valid_i           (psum_valid_w && !ext_en_i),

        .state_o                (controller_state_w),
        .rd_count_o             (rd_count_w),
        .wr_count_o             (wr_count_w),
        .k_count_o              (k_count_w),
        .n_count_o              (n_count_w),
        .start_pulse_o          (start_pulse_w)

    );

    // Instantiate the systolic array of the proper size
    systolic_array #(
        .INPUT_WIDTH    (WIDTH), 
        .ARRAY_W        (Tn), 
        .ARRAY_H        (Tk), 
        .ACCUM_WIDTH    (ARRAY_ACCUM_WIDTH)
    ) u_array (
        .clk_i          (clk_i), 
        .rstn_i         (rstn_i),
        .load_weight_i  (load_weight),
        .write_weight_i (write_weight),
        .weight_i       (array_weight),       // lane j = column j
        .act_valid_i    (act_valid),
        .act_i          (array_activation),   // lane k = reduction index k
        .psum_o         (array_psum_sys_w),
        .psum_valid_o   (psum_valid_w),
        .weight_xor_o   (weight_xor_w)
    );

    // Buffer the psum generated from the array because it needs to be added with partial sum read from
    // memory which won't be ready until next cycle
    generate
        for(genvar j=0; j < Tn; j++) begin : psum_buffer
            shift_buffer #(
                .DATA_WIDTH     (ARRAY_ACCUM_WIDTH),
                .BUFFER_LENGTH  (1)
            ) psum_buff (
                .clk_i      (clk_i),
                .rstn_i     (rstn_i),
                .data_i     (array_psum_sys_w[j]),
                .data_o     (array_psum_buff_w[j])
            );
        end
    endgenerate

    // Add the partial sum read from memory to the buffered partial sum from the buffer
    // If this is the first k tile, add the partial sum to 0
    generate
        for(genvar j=0; j < Tn; j++) begin : psum_addition
            assign array_psum_added_w[j] = first_k_w ? {array_psum_buff_w[j][ARRAY_ACCUM_WIDTH-1], array_psum_buff_w[j]} : {array_psum_buff_w[j][ARRAY_ACCUM_WIDTH-1], array_psum_buff_w[j][ARRAY_ACCUM_WIDTH-1:0]} + {{(ARRAY_ACCUM_WIDTH-ACCUM_WIDTH+1){ob_mem_data_R_i[j][ACCUM_WIDTH-1]}}, ob_mem_data_R_i[j][ACCUM_WIDTH-1:0]};
        end
    endgenerate

    // Saturate the summed partial sum to 16 bits and 8 bits in parallel and choose which to write back to memory
    generate
        for(genvar j=0; j < Tn; j++) begin : output_saturation
            saturate #(
                .INPUT_WIDTH    (ARRAY_ACCUM_WIDTH+1),
                .OUTPUT_WIDTH   (ACCUM_WIDTH)
            ) psum_sat (
                .data_i (array_psum_added_w[j]),
                .data_o (array_psum_sat_16_w[j]),
                .sat_o  (array_sat_16_psum_added_w[j])
            );
    
            saturate #(
                .INPUT_WIDTH  (ARRAY_ACCUM_WIDTH+1),
                .OUTPUT_WIDTH (WIDTH)
            ) output_sat (
                .data_i (array_psum_added_w[j]),
                .data_o (array_psum_sat_8_w[j]),
                .sat_o  (array_sat_8_psum_added_w[j])
            );
        end
    endgenerate

    // If this is last k, write the 8-bit saturated value to memory because it is the final output
    // otherwise keep the 16-bit precision for intermediate partial sums
    generate
        for(genvar j=0; j < Tn; j++) begin : output_select
            assign ob_mem_data_W_o[j] = last_k_w ? {{(ACCUM_WIDTH-WIDTH){array_psum_sat_8_w[j][WIDTH-1]}}, array_psum_sat_8_w[j]} : array_psum_sat_16_w[j];
        end
    endgenerate

    // Independent external saturation preserves Tk+Tn-1 latency and avoids
    // feeding unavailable psum-memory data into external/BiST arithmetic.
    for (genvar j=0; j<Tn; j++) begin : external_saturation
        saturate #(
            .INPUT_WIDTH    (ARRAY_ACCUM_WIDTH), 
            .OUTPUT_WIDTH   (WIDTH)
            ) ext_sat (
            .data_i (array_psum_sys_w[j]), 
            .data_o (external_result[j]),
            .sat_o  (array_sat_psum_sys_w[j])
        );
    end

    // The read port never writes data
    assign ob_mem_data_R_o      = '0;
    assign ext_result_o         = external_result;
    assign ext_valid_o          = rstn_i && ext_en_i && psum_valid_w;

    // or combine all of the saturation outputs so this signal goes high if any outputs are saturated
    assign sat_16_psum_added_or_w = | array_sat_16_psum_added_w;
    assign sat_8_psum_added_or_w = | array_sat_8_psum_added_w;
    assign sat_psum_sys_or_w = | array_sat_psum_sys_w;

    // Instantiate the debug mux
    debug_obs
    #(
        .WIDTH  (WIDTH),
        .Tn     (Tn),
        .Tk     (Tk)
    ) debug_mux (
        .clk_i                  (clk_i),
        .rstn_i                 (rstn_i),
        .extra_config_i         (data_config_i.extra_config_i),

        .state_i                (controller_state_w),
        .rd_count_i             (rd_count_w),
        .wr_count_i             (wr_count_w),
        .k_count_i              (k_count_w),
        .n_count_i              (n_count_w),
        .start_pulse_i          (start_pulse_w),
        .last_k_i               (last_k_w),

        .done_i                 (done_o),
        .ext_en_i               (ext_en_i),
        .load_weight_i          (load_weight),
        .act_valid_i            (act_valid),
        .psum_valid_i           (psum_valid_w),
        .psum_valid_delayed_i   (psum_valid_delayed_w),
        .ext_valid_i            (ext_valid_o),

        .weight_xor_i           (weight_xor_w),
        .sat16_i                (sat_16_psum_added_or_w),
        .sat8_i                 (sat_8_psum_added_or_w),
        .sat_ext_i              (sat_psum_sys_or_w),

        .obs_o                  (extra_output_bits_o.extra_config_o)
    );

endmodule
