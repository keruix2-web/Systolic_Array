`timescale 1ns/1ps
module mem_emulator #(parameter WIDTH=32, SIZE=256) (
	input  logic                    clk_i,
	input  logic                    cenb_i,	// memory enable, active low
	input  logic                    wenb_i,	// write enable, active low
	input  logic [$clog2(SIZE)-1:0] addr_i,	// address
	input  logic [WIDTH-1:0]        d_i,	// input data
	output logic [WIDTH-1:0]        q_o		// output data
);
    // registers
	logic [WIDTH-1:0] data [SIZE-1:0];
	
    // FF logic
	always @(posedge clk_i) begin
		if (~cenb_i) begin
			if (wenb_i) begin // read
				// q_o <= data[addr_i];			
				q_o <= #1 data[addr_i];			
			end else begin	// write
				data[addr_i] <= #1 d_i;			
			end
		end
	end

endmodule //mem_emulator
