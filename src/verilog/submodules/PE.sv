/******************************************************************************
 Module Name : PE
 Description :
	 Performs a multiply accumulate operation in a systolic array
     Output changes on the rising edge of the following clock

     In normal operation (load_weight_i and write_weight_i are low):
     east_o <= west_i
     south_o <= weight*west_i + north_i

     In weight loading operation, weights are passed down through the south output
     and the current weight is modified if write_weight_i goes high.
     write_weight_i should only ever go high if load_weight_i is high,
     otherwise a partial sum will be written to the weight
*******************************************************************************/

module PE 
    #(
        parameter   ACT_WIDTH=8,
        parameter   WEIGHT_WIDTH=8,
        // The internal sum width should be set to WEIGHT_WIDTH + ACT_WIDTH + log2(SYS_ARRAY_HEIGHT)
        // to ensure internal sums have full precision
        // In the case of a 4x4 systolic array with 8 bit inputs, this is 18
        parameter   INTERNAL_SUM_WIDTH=18
    )
    (
        input logic                                         clk_i,
        input logic                                         rstn_i,
        input logic                                         load_weight_i,
        input logic                                         write_weight_i,
        input logic signed      [ACT_WIDTH-1:0]             west_i,
        input logic signed      [INTERNAL_SUM_WIDTH-1:0]    north_i,
        output logic signed     [ACT_WIDTH-1:0]             east_o,
        output logic signed     [INTERNAL_SUM_WIDTH-1:0]    south_o,

        // Output the current weight for debug purposes
        output logic signed     [WEIGHT_WIDTH-1:0]          weight_o

    );

    // Internal signal to hold the weight of this PE
    logic signed [WEIGHT_WIDTH-1:0]         weight_r;

    // Internal signals to hold the next state of the outputs
    logic signed [INTERNAL_SUM_WIDTH-1:0]   south_next_r;
    logic signed [ACT_WIDTH-1:0]            east_next_r;

    // Combinational block to do the MAC calculation or load the weight onto the output
    always_comb begin
        if(load_weight_i)   south_next_r = north_i;
        else                south_next_r = weight_r * west_i + north_i;
        east_next_r = west_i;
    end

    // Flip-flop to change the output on the positive edge of the clock
    always_ff @(posedge clk_i) begin
        if(!rstn_i) begin
            east_o <= '0;
            south_o <= '0;
        end else begin
            east_o <= east_next_r;
            south_o <= south_next_r;
        end
    end

    // Flip-flop to update the internal weight of this block on the clock positive edge
    always_ff @(posedge clk_i) begin
        if(!rstn_i)                 weight_r <= '0;
        else if(write_weight_i)     weight_r <= north_i[WEIGHT_WIDTH-1:0];
    end

    // Assign the weight output to the registered weight value
    assign weight_o = weight_r;

endmodule