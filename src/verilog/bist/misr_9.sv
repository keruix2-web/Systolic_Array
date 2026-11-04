module misr_9 
#(
   parameter NUM_BITS = 64
)
(
   input  logic                  clk_i,
   input  logic                  rstn_i,
   input  logic                  bypass_i,
   input  logic                  done_i,
   input  logic [NUM_BITS-1:0]   seed_i,
   input  logic                  valid_i,
   input  logic [NUM_BITS-1:0]   data_i,
   output logic                  misr_valid_o,
   output logic [NUM_BITS-1:0]   misr_data_o
);

   logic [NUM_BITS:1]      r_misr_data;
   logic                   r_xnor;

   always_ff @(posedge clk_i or negedge rstn_i) begin
      if(~rstn_i) begin 
         r_misr_data    <= seed_i;
         misr_valid_o   <= '0;
      end
      else begin
         misr_valid_o <= bypass_i ? valid_i : done_i;
         
         r_misr_data <= r_misr_data;
         if (valid_i == 1'b1) begin
            if ( bypass_i ) begin
               r_misr_data <= data_i;
            end else begin
               if ( ~done_i ) begin
                  r_misr_data <= {r_misr_data[NUM_BITS-1:1], r_xnor} ^ data_i;
               end
            end
         end
      end
   end
 
   // https://docs.xilinx.com/v/u/en-US/xapp052
   // Taps for Maximum-Length LFSR Counters XNOR form
   always_comb begin
         r_xnor = r_misr_data[63] ^ r_misr_data[62] ^ r_misr_data[61] ^ r_misr_data[52];
   end
 
   assign misr_data_o = r_misr_data[NUM_BITS:1];
 
endmodule