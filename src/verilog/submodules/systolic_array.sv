/******************************************************************************
 Module Name : systolic_array
 Description :
	 
*******************************************************************************/

module systolic_array
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

    // Set the activations to 0 when the input is not valid
    assign gated_act_r = act_valid_i ? act_i : '0;

    // Create the input buffers
    generate
        for(genvar i=0; i < ARRAY_H; i++) begin : input_buffers
            shift_buffer
            #(
                .DATA_WIDTH     (INPUT_WIDTH),
                .BUFFER_LENGTH  (i)                 // Buffer lower rows longer to stagger inputs
            ) input_shift (
                .clk_i          (clk_i),
                .rstn_i         (rstn_i),
                .data_i         (gated_act_r[i][INPUT_WIDTH-1:0]),
                .data_o         (buffered_act_r[i][INPUT_WIDTH-1:0])
            );
        end
    endgenerate

    // Create the output data buffers
    generate
        for(genvar j=0; j < ARRAY_W; j++) begin : output_buffers
            shift_buffer 
            #(
                .DATA_WIDTH     (ACCUM_WIDTH),
                .BUFFER_LENGTH  (ARRAY_W-1-j)                   // Earlier columns need to be buffered longer because they generate data sooner
            ) output_shift (
                .clk_i          (clk_i),
                .rstn_i         (rstn_i),
                .data_i         (internal_psum_r[ARRAY_H][j][ACCUM_WIDTH-1:0]),
                .data_o         (psum_o[j][ACCUM_WIDTH-1:0])
            );
        end
    endgenerate

    // Create a buffer to output the valid signal with the same latency as the output becomes valid
    shift_buffer
    #(
        .DATA_WIDTH     (1),
        .BUFFER_LENGTH  (ARRAY_H + ARRAY_W - 1)
    ) valid_shift (
        .clk_i          (clk_i),
        .rstn_i         (rstn_i),
        .data_i         (act_valid_i),
        .data_o         (psum_valid_o)
    );

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
                PE
                #(
                    .ACT_WIDTH              (INPUT_WIDTH),
                    .WEIGHT_WIDTH           (INPUT_WIDTH),
                    .INTERNAL_SUM_WIDTH     (ACCUM_WIDTH)
                ) mac (
                    .clk_i          (clk_i),
                    .rstn_i         (rstn_i),
                    .load_weight_i  (load_weight_i),
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