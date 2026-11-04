/******************************************************************************
 Module Name : shift_buffer
 Description :
	 Buffers input to or output from the systolic array, shifting elements
     forward in the buffer each cycle

     By using instantiations of this buffer of different lengths, input and 
     output is properly staggered so that memory reads and writes can
     be completed a full row at a time

     When BUFFER_LENGTH=0, input is directly connected to output
*******************************************************************************/

module shift_buffer
    #(
        parameter DATA_WIDTH=8,     // Set to 16 for outputs because of partial sums
        parameter BUFFER_LENGTH=4
    )
    (
        input logic                         clk_i,
        input logic                         rstn_i,
        input logic     [DATA_WIDTH-1:0]    data_i,
        output logic    [DATA_WIDTH-1:0]    data_o
    );

    // Use a generate so we can deal with the BUFFER_LENGTH=0 case the width of the buffer is 0
    generate
        // When the buffer length is 0, we simply create a wire connecting input to output
        if(BUFFER_LENGTH == 0) begin: passthrough
            assign data_o = data_i;

        end else begin: shift
            // Internal array to hold data in the buffer
            logic [BUFFER_LENGTH-1:0][DATA_WIDTH-1:0] stored_data;

            // On every clock cycle, advance the data through the buffer
            always_ff @(posedge clk_i) begin
                if(!rstn_i) begin
                    stored_data <= '0;
                end else begin
                    // Shift the elements in the data array to advance one slot
                    stored_data <= stored_data << DATA_WIDTH;
                    // Override the lowest elements in the array to the new input data
                    stored_data[0][DATA_WIDTH-1:0] <= data_i;
                end
            end

            // Use combinational logic to send the last buffer item to the output
            // This ensures that it takes BUFFER_LENGTH cycles before the input is on the output
            assign data_o = stored_data[BUFFER_LENGTH-1][DATA_WIDTH-1:0];
            
        end
    endgenerate

endmodule