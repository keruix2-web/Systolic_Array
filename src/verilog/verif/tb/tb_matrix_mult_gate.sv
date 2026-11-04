// Gate-level memory-mode testbench (post-synthesis and post-APR).
//
// Same tests as tb_matrix_mult (golden tests from tests.list plus the directed tests in
// tb_matrix_mult_tasks.sv), but the DUT is the matrix_mult_wrapper_9 netlist. Only the wrapper
// is guaranteed to be a module in the netlist, so the core is reached through it. The bound
// checkers need RTL internals and are not compiled, so every check here comes from the tasks:
// golden + SV reference comparison, done_o behaviour, stray writes and the debug pages.
//
// The Makefile annotates the SDF onto tb_matrix_mult_gate.dut, so the instance must keep that name.
module tb_matrix_mult_gate;
   import matrix_mult_pkg::*;
   // Matrix Dimensions: [# rows, # cols]
   //     Input * Weight = Output
   //    [M, K] * [K, N] = [M, N]
   parameter M             = 4;
   parameter N             = 4;
   parameter K             = 4;

   // Tiling / Hardware Tile Parameters
   parameter Tm            = 4;            // Hardware array tile rows
   parameter Tn            = 4;            // Hardware array tile cols
   parameter Tk            = 4;            // Hardware tile K depth

   // Matrix Mult parameters (must match the values the netlist was synthesized with)
   parameter WIDTH         = 8;            // datawidth
   parameter ACCUM_WIDTH   = 16;           // accumulator width (output/psum memory)
   parameter ROW           = Tm;           // systolic array # of rows (mapped to Tm)
   parameter COL           = Tn;           // systolic array # of cols (mapped to Tn)
   parameter W_SIZE        = 1024;         // weight memory height
   parameter I_SIZE        = 1024;         // input act memory height
   parameter O_SIZE        = 1024;         // output memory height
   parameter DRIVER_WIDTH  = WIDTH * ( Tm + Tn );

   parameter CLOCK_PERIOD  = 8;
   parameter real DUTY_CYCLE = 0.5;
   parameter real OFFSET   = 2.5;

   // Check that each 16-bit output lane is the sign extension of the 8-bit result
   parameter bit  CHECK_SIGN_EXT = 1'b1;

   // --- Matrix Mult Signals --- //
   logic                         clk_i;
   logic                         rst_n;          // drives the wrapper's rstn_async_i

   // output buffer memory - Read Port
   logic                         ob_mem_cenb_R_o;
   logic                         ob_mem_wenb_R_o;
   logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_R_o;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_i;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_o;

   // output buffer memory - Write Port
   logic                         ob_mem_cenb_W_o;
   logic                         ob_mem_wenb_W_o;
   logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_W_o;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_i;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_o;

   // input buffer memory
   logic                         ib_mem_cenb_o;
   logic                         ib_mem_wenb_o;
   logic [$clog2(I_SIZE)-1:0]    ib_mem_addr_o;
   logic [Tm-1:0][WIDTH-1:0]     ib_mem_data_i;

   // weights buffer memory
   logic                         wb_mem_cenb_o;
   logic                         wb_mem_wenb_o;
   logic [$clog2(W_SIZE)-1:0]    wb_mem_addr_o;
   logic [Tn-1:0][WIDTH-1:0]     wb_mem_data_i;

   logic                         start_i;
   logic                         done_o;

   // Wrapper control signals
   logic                         en_i;
   logic                         ext_en_i;
   test_config_struct            test_config_i;
   data_config_struct            data_config_i;
   external_inputs_struct        ext_inputs_i;

   // Wrapper monitor signals (unused in memory mode)
   logic [DRIVER_WIDTH-1:0]      ext_result_o;
   logic                         ext_valid_o;
   extra_output_bits_struct      extra_output_bits_o;

   // testbench variables
   logic [1000:0]                testname;
   logic                         write_files;
   integer                       returnval;
   string                        filename;

   string                        current_test;


   // Instantiate clock
   initial begin
      #OFFSET;
      forever begin
         clk_i = 1'b0;
         #(CLOCK_PERIOD-(CLOCK_PERIOD*DUTY_CYCLE)) clk_i = 1'b1;
         #(CLOCK_PERIOD*DUTY_CYCLE);
      end
   end

   // -- Memory Instance: Input Buffer Memory -- //
   mem_emulator #(.WIDTH(Tm*WIDTH), .SIZE(I_SIZE))
      ib_mem (
         .clk_i   (clk_i),
         .cenb_i  (ib_mem_cenb_o),
         .wenb_i  (ib_mem_wenb_o),
         .addr_i  (ib_mem_addr_o),
         .d_i     (),
         .q_o     (ib_mem_data_i)
   );

   // -- Memory Instance: Weight Buffer Memory -- //
   mem_emulator #(.WIDTH(Tn*WIDTH), .SIZE(W_SIZE))
      wb_mem (
         .clk_i   (clk_i),
         .cenb_i  (wb_mem_cenb_o),
         .wenb_i  (wb_mem_wenb_o),
         .addr_i  (wb_mem_addr_o),
         .d_i     (),
         .q_o     (wb_mem_data_i)
   );

   // -- Memory Instance: Output Buffer Memory -- //
   mem2p_emulator #(.WIDTH(Tn*ACCUM_WIDTH), .SIZE(O_SIZE))
      ob_mem (
         .clk_i    (clk_i),
         .cenb_a_i (ob_mem_cenb_R_o),
         .wenb_a_i (ob_mem_wenb_R_o),
         .addr_a_i (ob_mem_addr_R_o),
         .d_a_i    (ob_mem_data_R_o),
         .q_a_o    (ob_mem_data_R_i),

         .cenb_b_i (ob_mem_cenb_W_o),
         .wenb_b_i (ob_mem_wenb_W_o),
         .addr_b_i (ob_mem_addr_W_o),
         .d_b_i    (ob_mem_data_W_o),
         .q_b_o    (ob_mem_data_W_i)
   );

   // Power for the post-APR netlist (the APR Makefile defines PG_PINS)
   supply1                       VDD;
   supply0                       VSS;

   // -- DUT Instance: Matrix Mult Wrapper netlist -- //
   // No parameter overrides: the netlist has none. Struct ports are flat vectors in the netlist.
   matrix_mult_wrapper_9 dut (
      `ifdef PG_PINS
      .VDD                 (VDD),
      .VSS                 (VSS),
      `endif
      .clk_i               (clk_i),
      .rstn_async_i        (rst_n),
      .en_i                (en_i),
      .start_i             (start_i),
      .test_config_i       (test_config_i),
      .data_config_i       (data_config_i),

      .ob_mem_cenb_R_o     (ob_mem_cenb_R_o),
      .ob_mem_wenb_R_o     (ob_mem_wenb_R_o),
      .ob_mem_addr_R_o     (ob_mem_addr_R_o),
      .ob_mem_data_R_i     (ob_mem_data_R_i),
      .ob_mem_data_R_o     (ob_mem_data_R_o),

      .ob_mem_cenb_W_o     (ob_mem_cenb_W_o),
      .ob_mem_wenb_W_o     (ob_mem_wenb_W_o),
      .ob_mem_addr_W_o     (ob_mem_addr_W_o),
      .ob_mem_data_W_i     (ob_mem_data_W_i),
      .ob_mem_data_W_o     (ob_mem_data_W_o),

      .ib_mem_cenb_o       (ib_mem_cenb_o),
      .ib_mem_wenb_o       (ib_mem_wenb_o),
      .ib_mem_addr_o       (ib_mem_addr_o),
      .ib_mem_data_i       (ib_mem_data_i),

      .wb_mem_cenb_o       (wb_mem_cenb_o),
      .wb_mem_wenb_o       (wb_mem_wenb_o),
      .wb_mem_addr_o       (wb_mem_addr_o),
      .wb_mem_data_i       (wb_mem_data_i),

      .ext_en_i            (ext_en_i),
      .ext_inputs_i        (ext_inputs_i),
      .ext_result_o        (ext_result_o),
      .ext_valid_o         (ext_valid_o),

      .done_o              (done_o),
      .extra_output_bits_o (extra_output_bits_o)
   );


   initial begin : TEST_CASE
      `ifndef NO_FSDB
         $fsdbDumpfile("matrix_mult.fsdb");
         $fsdbDumpon;
         $fsdbDumpvars(0, tb_matrix_mult_gate, "+mda", "+all", "+trace_process");
      `endif

      init_tb_signals();
      // en_i gates the wrapper clock (g_clk = clk_i & en_i). init_tb_signals clears it because
      // the core-level testbench does not use it, so turn the clock on here.
      en_i = 1'b1;
      run_all_tests();
      $finish;
   end

   // Memory-mode test sequences, golden comparison and stimulus coverage
   `include "tb_matrix_mult_tasks.sv"
endmodule
