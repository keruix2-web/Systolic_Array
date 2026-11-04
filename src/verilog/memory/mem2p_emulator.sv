`timescale 1ns/1ps
module mem2p_emulator #(parameter WIDTH=32, SIZE=256) (
	input  logic                    clk_i,

	// Port A
	input  logic                    cenb_a_i,	// memory enable, active low
	input  logic                    wenb_a_i,	// write enable, active low
	input  logic [$clog2(SIZE)-1:0] addr_a_i,	// address
	input  logic [WIDTH-1:0]        d_a_i,	// input data
	output logic [WIDTH-1:0]        q_a_o,	// output data

	// Port B
	input  logic                    cenb_b_i,	// memory enable, active low
	input  logic                    wenb_b_i,	// write enable, active low
	input  logic [$clog2(SIZE)-1:0] addr_b_i,	// address
	input  logic [WIDTH-1:0]        d_b_i,	// input data
	output logic [WIDTH-1:0]        q_b_o	// output data
);
    // registers
	logic [WIDTH-1:0] data [SIZE-1:0];


	always @(posedge clk_i) begin
		if (cenb_a_i == 1'b0) begin
			if (wenb_a_i == 1'b0) begin
				data[addr_a_i] <= #1 d_a_i;
			end else begin
				q_a_o <= #1 data[addr_a_i];
			end
		end

		if (cenb_b_i == 1'b0) begin
			if (wenb_b_i == 1'b0) begin
				data[addr_b_i] <= #1 d_b_i;
			end else begin
				q_b_o <= #1 data[addr_b_i];
			end
		end
	end
endmodule //2pmem_emulator
