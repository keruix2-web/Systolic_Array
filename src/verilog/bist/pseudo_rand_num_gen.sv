
module pseudo_rand_num_gen_9
#(
   parameter DATA_WIDTH = 64
)
(
   input  logic                  clk_i,
   input  logic                  rstn_i,
   input  logic                  bypass_i,
   input  logic                  valid_i,
   input  logic [DATA_WIDTH-1:0] seed_i, // data or seed
   input  logic [DATA_WIDTH-1:0] stop_code_i,
   output logic                  valid_o,
   output logic [DATA_WIDTH-1:0] data_o,
   output logic                  done_o
);

   import pseudo_rand_num_gen_pkg::*;

   st_prng_state                 r_state, r_next_state;
   logic                         lfsr_en, lfsr_done;
   
   //state update (ff)
   always_ff @(posedge clk_i or negedge rstn_i) 
      if(~rstn_i)    r_state <= IDLE;
      else           r_state <= r_next_state;

   //next state (combo)
   always_comb begin
      case (r_state)
	      IDLE:    r_next_state = RUN;
         RUN:     r_next_state = lfsr_done ? DONE:RUN;
         DONE:    r_next_state = DONE;
         default: r_next_state = IDLE;
      endcase
   end
   
   //next logic (combo+ff)    //test mode ? 1-internal : 0-external 
   assign lfsr_en    = bypass_i ? valid_i : (r_next_state == RUN);

   lfsr_9 #(
      .NUM_BITS(DATA_WIDTH)
   ) lfsr_0 (
      .clk_i         (clk_i         ),
      .rstn_i        (rstn_i        ),
      .bypass_i      (bypass_i      ),
      .en_i          (lfsr_en       ),
      .valid_i       (valid_i       ),
      .seed_i        (seed_i        ),
      .stop_code_i   (stop_code_i   ),
      .lfsr_valid_o  (valid_o       ),
      .lfsr_data_o   (data_o        ),
      .lfsr_done_o   (lfsr_done     )
   );

   assign done_o = (r_next_state == DONE); 
   
endmodule