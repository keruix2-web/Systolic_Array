module lfsr_9 
#(
   parameter NUM_BITS = 64
)
(
   input  logic                   clk_i,
   input  logic                   rstn_i,
   input  logic                   bypass_i,
   input  logic                   en_i,
   input  logic                   valid_i,
   input  logic [NUM_BITS-1:0]    seed_i,
   input  logic [NUM_BITS-1:0]    stop_code_i,
   output logic                   lfsr_valid_o,
   output logic [NUM_BITS-1:0]    lfsr_data_o,
   output logic                   lfsr_done_o
);
 
    logic    [NUM_BITS-1:0]    r_lfsr_data_r;
    logic                    r_xnor;

   always @(posedge clk_i or negedge rstn_i) begin
      if(~rstn_i) begin
         r_lfsr_data_r  <= seed_i;
         lfsr_valid_o   <= '0;
      end
      else begin 
        lfsr_valid_o    <=  bypass_i ? valid_i : valid_i & en_i;

        if (valid_i & bypass_i) begin
            r_lfsr_data_r <= seed_i;
        end else if (valid_i & en_i ) begin
            r_lfsr_data_r <= {r_lfsr_data_r[NUM_BITS-2:0], r_xnor};
        end else begin 
            r_lfsr_data_r <= r_lfsr_data_r; 
        end
      end
   end
   
   // https://docs.xilinx.com/v/u/en-US/xapp052
   // Taps for Maximum-Length LFSR Counters XNOR form
   // below is an alternative approach
   always_comb begin
      r_xnor = r_lfsr_data_r[63] ^ r_lfsr_data_r[62] ^ r_lfsr_data_r[61] ^ r_lfsr_data_r[52];
   end
 
   assign lfsr_data_o = r_lfsr_data_r[NUM_BITS-1:0];
   assign lfsr_done_o =( r_lfsr_data_r[NUM_BITS-1:0] == stop_code_i ) ? 1'b1 : 1'b0;
 
endmodule