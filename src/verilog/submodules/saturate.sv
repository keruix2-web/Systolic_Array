/******************************************************************************
 Module Name : saturate
 Description :
	 Saturate the input to a two's compliment number that fits in the 
     specified number of output bits

     Used for saturating output to 8 bits and partial sums to 16 bits

     OUTPUT_WIDTH must be greater than or equal to INPUT_WIDTH
*******************************************************************************/

module saturate 
    #(
        parameter   INPUT_WIDTH=18,
        parameter   OUTPUT_WIDTH=16
    )
    (
        input logic signed [INPUT_WIDTH-1:0]        data_i,
        output logic signed [OUTPUT_WIDTH-1:0]      data_o,

        // Output a signal to indicate when the input is saturated for debug
        output logic                                sat_o
    );

    // Calculate the maximum and minimum possible value that can be held by the output width
    localparam logic signed [INPUT_WIDTH-1:0] MAX = (INPUT_WIDTH'(1) << (OUTPUT_WIDTH-1)) - 1;
    localparam logic signed [INPUT_WIDTH-1:0] MIN = -(INPUT_WIDTH'(1) << (OUTPUT_WIDTH-1));

    // Use purely combinational logic to calculate the saturated output
    always_comb begin
        // Only saturate the output if it is outside the bounds
        if(data_i > MAX)            data_o = MAX[OUTPUT_WIDTH-1:0];
        else if (data_i < MIN)      data_o = MIN[OUTPUT_WIDTH-1:0];
        else                        data_o = data_i[OUTPUT_WIDTH-1:0];
    end

    // Raise the sat_o signal high when the input is is a value that will be saturated
    assign sat_o = (data_i > MAX) || (data_i < MIN);

endmodule