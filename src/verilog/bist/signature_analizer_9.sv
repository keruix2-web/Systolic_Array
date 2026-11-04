
module signature_analyzer_9 
#(
   parameter DATA_WIDTH = 64
)
(
   input  logic                  clk_i,
   input  logic                  rstn_i,
   input  logic                  bypass_i,
   input  logic                  stop_i,
   input  logic [DATA_WIDTH-1:0] seed_i,
   input  logic                  dut_valid_i,
   input  logic [DATA_WIDTH-1:0] dut_data_i,
   output logic                  valid_o,
   output logic [DATA_WIDTH-1:0] data_o
);

   import pseudo_rand_num_gen_pkg::*;

   st_prng_state          r_state, r_next_state;
   logic                  misr_done;
   
   //state update (ff)
   always_ff @(posedge clk_i or negedge rstn_i) 
      if(~rstn_i)   r_state <= IDLE;
      else          r_state <= r_next_state;
   
   //next state (combo)
   always_comb begin
      case (r_state)
	     IDLE:      r_next_state = RUN;
         RUN:       r_next_state = stop_i ? DONE : RUN;
         DONE:      r_next_state = DONE;
         default:   r_next_state = IDLE;
      endcase
   end
   
   //next logic (combo+ff)
   assign misr_done  = r_next_state == DONE;

   misr_9 #(
      .NUM_BITS(DATA_WIDTH)
   ) misr_0 (
      .clk_i        (clk_i          ),
      .rstn_i       (rstn_i         ),
      .bypass_i     (bypass_i       ),
      .done_i       (misr_done      ),
      .seed_i       (seed_i         ),
      .valid_i      (dut_valid_i    ),
      .data_i       (dut_data_i     ),
      .misr_valid_o (valid_o        ),
      .misr_data_o  (data_o         )
   );
   
endmodule