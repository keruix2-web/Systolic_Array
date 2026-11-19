/******************************************************************************
 Module Name : systolic_array
 Description :
	 
*******************************************************************************/

module systolic_array_9
    #(
        parameter INPUT_WIDTH=8,
        parameter ARRAY_W=4,
        parameter ARRAY_H=4,
        parameter ACCUM_WIDTH=2*INPUT_WIDTH + $clog2(ARRAY_H)   //18 for our 4x4 array
    )
    (
        input logic                                 clk_i,
        input logic                                 rstn_i,
        input logic                                 load_weight_i,      // weight_i holds a valid row this cycle
        input logic                                 write_weight_i,     // Assert last weight load cycle to write weights to each PE
        input logic [ARRAY_W-1:0][INPUT_WIDTH-1:0]  weight_i,
        input logic                                 act_valid_i,        // act_i holds a valid row this cycle
        input logic [ARRAY_H-1:0][INPUT_WIDTH-1:0]  act_i,        
        output logic [ARRAY_W-1:0][ACCUM_WIDTH-1:0] psum_o,             // de-skewed, full precision array output
        output logic                                psum_valid_o,

        // For debug purposes output the xor of all the stored PE weights
        output logic [INPUT_WIDTH-1:0]              weight_xor_o
    );

    // Create an internal activation row to hold activation input when it is valid and 0 otherwise
    logic [ARRAY_H-1:0][INPUT_WIDTH-1:0] gated_act_r;

    // Create an internal array of buffered activations to hold the shifted input for each cycle
    logic [ARRAY_H-1:0][INPUT_WIDTH-1:0] buffered_act_r;

    // Internal signals to connect PEs together (one wider/taller than systolic array to hold outputs from the array)
    logic [ARRAY_H-1:0][ARRAY_W:0][INPUT_WIDTH-1:0] internal_act_r;
    logic [ARRAY_H:0][ARRAY_W-1:0][ACCUM_WIDTH-1:0] internal_psum_r;

    // Internal weight outputs for debug purposes
    logic [ARRAY_H-1:0][ARRAY_W-1:0][INPUT_WIDTH-1:0] internal_weight_r;

    // Per-row load weight signal. Row i is put in weight pass-through mode i cycles after row 0,
    // the same cycle the first weight reaches it. This lets the top rows start loading the next
    // tile's weights while the lower rows are still finishing the last partial sums of this tile.
    // write_weight_i stays global: on that cycle every row has the load signal high.
    logic [ARRAY_H-1:0] load_row_w;

    // Activation valid pipeline. act_valid_d_w[d] is act_valid_i from d cycles ago. A row that enters
    // with act_valid_i is at PE(i,j) when act_valid_d_w[i+j] is high, so these taps are the clock
    // enables for the PEs and shift buffers. The last tap is psum_valid_o
    localparam VALID_DEPTH = ARRAY_H + ARRAY_W - 1;
    logic [VALID_DEPTH:0] act_valid_d_w;
    logic [VALID_DEPTH:1] act_valid_d_r;

    // Clock enables. A PE is enabled while its row loads weights or a valid row is passing through it.
    // A shift buffer is enabled while a valid row is entering or inside it
    logic [ARRAY_H-1:0][ARRAY_W-1:0] pe_en_w;
    logic [ARRAY_H-1:0] in_buf_en_w;
    logic [ARRAY_W-1:0] out_buf_en_w;

    generate
        if(ARRAY_H == 1) begin : load_no_delay
            assign load_row_w = load_weight_i;
        end else begin : load_delay
            // load_delay_r[i-1] holds load_weight_i from i cycles ago
            logic [ARRAY_H-2:0] load_delay_r;
            // Only shift while a load bit is in the delay line so it is gated outside weight loading
            // | operator ors all values in load_row_w so if any row is valid, the shift register is active
            always_ff @(posedge clk_i) begin
                if(!rstn_i)             load_delay_r <= '0;
                else if(|load_row_w)    load_delay_r <= load_row_w[ARRAY_H-2:0];
            end
            assign load_row_w = {load_delay_r, load_weight_i};
        end
    endgenerate

    // Only shift while a valid bit is in the pipeline so it is gated when the array is idle
    always_ff @(posedge clk_i) begin
        if(!rstn_i)             act_valid_d_r <= '0;
        else if(|act_valid_d_w) act_valid_d_r <= act_valid_d_w[VALID_DEPTH-1:0];
    end
    assign act_valid_d_w = {act_valid_d_r, act_valid_i};
    assign psum_valid_o = act_valid_d_r[VALID_DEPTH];

    always_comb begin
        // PE(i,j) is enabled when its row is preforming weight loading or it is processing valid data
        for(int i=0; i < ARRAY_H; i++)
            for(int j=0; j < ARRAY_W; j++)
                pe_en_w[i][j] = load_row_w[i] || act_valid_d_w[i+j];

        // Input buffer i (length i) holds a row from when it enters (tap 0) until it leaves (tap i-1)
        for(int i=0; i < ARRAY_H; i++) begin
            in_buf_en_w[i] = 1'b0;
            for(int d=0; d < i; d++)
                in_buf_en_w[i] = in_buf_en_w[i] || act_valid_d_w[d];
        end

        // Output buffer j (length ARRAY_W-1-j) takes the bottom PE output one cycle after that PE
        // computes (tap ARRAY_H+j) and shifts it until the row is on psum_o (tap VALID_DEPTH-1)
        for(int j=0; j < ARRAY_W; j++) begin
            out_buf_en_w[j] = 1'b0;
            for(int d=ARRAY_H+j; d < VALID_DEPTH; d++)
                out_buf_en_w[j] = out_buf_en_w[j] || act_valid_d_w[d];
        end
    end

    // Set the activations to 0 when the input is not valid
    // The buffers no longer need this for correctness, but it stops act_i toggling the row 0 MACs
    assign gated_act_r = act_valid_i ? act_i : '0;

    // Create the input buffers
    generate
        for(genvar i=0; i < ARRAY_H; i++) begin : input_buffers
            shift_buffer_9
            #(
                .DATA_WIDTH     (INPUT_WIDTH),
                .BUFFER_LENGTH  (i)                 // Buffer lower rows longer to stagger inputs
            ) input_shift (
                .clk_i          (clk_i),
                .rstn_i         (rstn_i),
                .en_i           (in_buf_en_w[i]),
                .data_i         (gated_act_r[i][INPUT_WIDTH-1:0]),
                .data_o         (buffered_act_r[i][INPUT_WIDTH-1:0])
            );
        end
    endgenerate

    // Create the output data buffers
    generate
        for(genvar j=0; j < ARRAY_W; j++) begin : output_buffers
            shift_buffer_9
            #(
                .DATA_WIDTH     (ACCUM_WIDTH),
                .BUFFER_LENGTH  (ARRAY_W-1-j)                   // Earlier columns need to be buffered longer because they generate data sooner
            ) output_shift (
                .clk_i          (clk_i),
                .rstn_i         (rstn_i),
                .en_i           (out_buf_en_w[j]),
                .data_i         (internal_psum_r[ARRAY_H][j][ACCUM_WIDTH-1:0]),
                .data_o         (psum_o[j][ACCUM_WIDTH-1:0])
            );
        end
    endgenerate

    // Set the first column of internal activations to the buffered activations
    generate
        for(genvar i=0; i < ARRAY_H; i++) begin : activation_inpus
            assign internal_act_r[i][0][INPUT_WIDTH-1:0] = buffered_act_r[i][INPUT_WIDTH-1:0];
        end
    endgenerate

    // Set the first row of internal partial sums to the padded weights (which will be truncated by the PE when capturing weights)
    generate
        for(genvar j=0; j < ARRAY_W; j++) begin : weight_inputs
            // If the weights are not being loaded, set this row to 0 to ensure calculations are correct
            // Sign extend the weight to fill the full partial sum bits
            assign internal_psum_r[0][j] = load_weight_i ? {{(ACCUM_WIDTH-INPUT_WIDTH){weight_i[j][INPUT_WIDTH-1]}}, weight_i[j]} : '0;
        end
    endgenerate

    // Create the systolic array using generate statements to instantiate PEs
    generate
        for(genvar i=0; i < ARRAY_H; i++) begin
            for(genvar j=0; j < ARRAY_W; j++) begin : systolic
                PE_9
                #(
                    .ACT_WIDTH              (INPUT_WIDTH),
                    .WEIGHT_WIDTH           (INPUT_WIDTH),
                    .INTERNAL_SUM_WIDTH     (ACCUM_WIDTH)
                ) mac (
                    .clk_i          (clk_i),
                    .rstn_i         (rstn_i),
                    .en_i           (pe_en_w[i][j]),
                    .load_weight_i  (load_row_w[i]),
                    .write_weight_i (write_weight_i),
                    .west_i         (internal_act_r[i][j][INPUT_WIDTH-1:0]),
                    .north_i        (internal_psum_r[i][j][ACCUM_WIDTH-1:0]),
                    .east_o         (internal_act_r[i][j+1][INPUT_WIDTH-1:0]),
                    .south_o        (internal_psum_r[i+1][j][ACCUM_WIDTH-1:0]),
                    .weight_o       (internal_weight_r[i][j][INPUT_WIDTH-1:0])
                );
            end
        end
    endgenerate

    // Create an xor tree that sets the weight xor output to the xor of all internal weights
    always_comb begin
        weight_xor_o = '0;
        for(int i=0; i < ARRAY_H; i++) begin
            for(int j=0; j < ARRAY_W; j++) begin
                weight_xor_o = weight_xor_o ^ internal_weight_r[i][j];
            end
        end
    end

endmodule