import matrix_mult_pkg::*;

module matrix_mult_wrapper_9 #(
    parameter WIDTH             = 8, 
    parameter ACCUM_WIDTH       = 16,
    parameter ARRAY_ACCUM_WIDTH = 18,
    parameter ROW               = 4, 
    parameter COL               = 4, 
    parameter Tm                = 4,
    parameter Tn                = 4,
    parameter Tk                = 4,
    parameter M                 = 64,
    parameter N                 = 64,
    parameter K                 = 64,
    parameter W_SIZE            = 1024, 
    parameter I_SIZE            = 1024, 
    parameter O_SIZE            = 1024,
    parameter MEM_R_WIDTH       = WIDTH * Tm,
    parameter MEM_C_WIDTH       = WIDTH * Tn,
    parameter MEM_C_ACCUM_WIDTH = ACCUM_WIDTH * Tn,
    parameter DRIVER_WIDTH      = WIDTH * ( Tm + Tn )
) (
  input  logic                            clk_i,            // clock signal
  input  logic                            rstn_async_i,     // active low reset signal
  input  logic                            en_i,             // global clock enable
  input  logic                            start_i,          // active high start calculation, must reset back to 0 first to start a new calculation
  input  test_config_struct               test_config_i,    // test controls
  input  data_config_struct               data_config_i,    // data controls
  // output buffer memory - Read Port
  output  logic                           ob_mem_cenb_R_o,  // memory enable, active low
  output  logic                           ob_mem_wenb_R_o,  // write enable, active low
  output  logic [$clog2(O_SIZE)-1:0]      ob_mem_addr_R_o,  // address
  input   logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_R_i,  // input data
  output  logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_R_o,  // output data
  // output buffer memory - Write Port
  output  logic                           ob_mem_cenb_W_o,  // memory enable, active low
  output  logic                           ob_mem_wenb_W_o,  // write enable, active low
  output  logic [$clog2(O_SIZE)-1:0]      ob_mem_addr_W_o,  // address
  input   logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_W_i,  // input data
  output  logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_W_o,  // output data
  // input buffer memory
  output  logic                           ib_mem_cenb_o,    // memory enable, active low
  output  logic                           ib_mem_wenb_o,    // write enable, active low
  output  logic [$clog2(I_SIZE)-1:0]      ib_mem_addr_o,    // address
  input   logic [MEM_R_WIDTH-1:0]         ib_mem_data_i,    // input data
  // weights buffer memory
  output  logic                           wb_mem_cenb_o,    // memory enable, active low
  output  logic                           wb_mem_wenb_o,    // write enable, active low
  output  logic [$clog2(W_SIZE)-1:0]      wb_mem_addr_o,    // address
  input   logic [MEM_C_WIDTH-1:0]         wb_mem_data_i,    // input data
  // external mode
  input  logic                            ext_en_i,         // external mode enable, active high
  input  external_inputs_struct           ext_inputs_i,     // external inputs
  output logic [DRIVER_WIDTH-1:0]         ext_result_o,     // external outputs
  output logic                            ext_valid_o,      // external valid output
  // done
  output logic                            done_o,            // active high finish signal, goes to 1 after reset
  output extra_output_bits_struct         extra_output_bits_o
);

  logic                       rstn_i;
  logic                       dut_bypass_w;
  logic                       g_clk;

  logic                       driver_bypass_w;
  logic                       driver_mode_w;
  logic [DRIVER_WIDTH-1:0]    driver_seed_w;
  logic                       driver_valid_o_w;
  logic [DRIVER_WIDTH-1:0]    driver_data_w;
  logic                       driver_done_w;

  logic                       sa_bypass_w;
  logic                       sa_mode_w;
  logic                       sa_dut_valid_w;
  logic [DRIVER_WIDTH-1:0]    sa_dut_data_w;
  logic                       sa_valid_w;
  logic [DRIVER_WIDTH-1:0]    sa_data_w;
  logic [DRIVER_WIDTH-1:0]    sa_seed_w;
  logic                       sa_stop_w;


  logic [Tm-1:0][WIDTH-1:0]        ext_input_w;
  logic                            ext_valid_i_w;
  logic [Tn-1:0][WIDTH-1:0]        ext_psum_w;
  logic [Tn-1:0][WIDTH-1:0]        ext_result_w;
  logic                            ext_valid_o_w;

  external_inputs_struct           ext_inputs_w;

  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_R_i_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_R_o_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_W_i_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_W_o_w;
  logic [Tm-1:0][WIDTH-1:0]        ib_mem_data_i_w;
  logic [Tn-1:0][WIDTH-1:0]        wb_mem_data_i_w;

  // explicitly convert 1D arrays to 2D arrays
  assign ob_mem_data_R_i_w = ob_mem_data_R_i ;
  assign ob_mem_data_R_o   = ob_mem_data_R_o_w ;
  assign ob_mem_data_W_i_w = ob_mem_data_W_i ;
  assign ob_mem_data_W_o   = ob_mem_data_W_o_w ;
  assign ib_mem_data_i_w   = ib_mem_data_i ;
  assign wb_mem_data_i_w   = wb_mem_data_i ;

  // global clock
  assign g_clk             = clk_i & en_i;

  // test control signals
  assign driver_bypass_w   = test_config_i.bypass[0];
  assign dut_bypass_w      = test_config_i.bypass[1];
  assign sa_bypass_w       = test_config_i.bypass[2];

  assign driver_mode_w     = test_config_i.mode[0];
  assign sa_mode_w         = test_config_i.mode[1];

  // connect seeds
  assign driver_seed_w     = { ext_inputs_i.ext_input, ext_inputs_i.ext_psum };
  assign sa_seed_w         = { ext_inputs_i.ext_psum, ext_inputs_i.ext_input };

  // bypass external inputs that never go through the driver
  assign ext_inputs_w.ext_weight_en   = ext_inputs_i.ext_weight_en;
  assign ext_inputs_w.ext_input       = ext_input_w;
  // A bypassed core need not have weights loaded for driver/monitor loopback.
  assign ext_inputs_w.ext_valid       = ext_valid_i_w && !dut_bypass_w;
  assign ext_inputs_w.ext_weight      = ext_inputs_i.ext_weight ;
  assign ext_inputs_w.ext_psum        = ext_psum_w;

  //-------------------------------------------------------------------------//
  //    Reset synchronizer                                                   //
  //-------------------------------------------------------------------------//
  async_nreset_synchronizer_9 async_nreset_synchronizer_0 (
     .clk_i            (g_clk            )
    ,.async_nreset_i   (rstn_async_i     )
    ,.rstn_o           (rstn_i           )
  );

  //-------------------------------------------------------------------------//
  //    Driver                                                               //
  //-------------------------------------------------------------------------//
  pseudo_rand_num_gen_9 #(.DATA_WIDTH (DRIVER_WIDTH))
    driver_0 (
      .clk_i        (g_clk                            ),
      .rstn_i       (rstn_i                           ),
      .bypass_i     (driver_mode_w                    ),
      .valid_i      (test_config_i.driver_valid       ),
      .seed_i       (driver_seed_w                    ),
      .stop_code_i  (test_config_i.driver_stop_code   ),
      .valid_o      (driver_valid_o_w                 ),
      .data_o       (driver_data_w                    ),
      .done_o       (driver_done_w                    )
    );

  // driver bypass
  assign { ext_input_w, ext_psum_w } = ( driver_bypass_w)  ? { ext_inputs_i.ext_input, ext_inputs_i.ext_psum } : driver_data_w;
  assign ext_valid_i_w               = ( driver_bypass_w)  ? ext_inputs_i.ext_valid : driver_valid_o_w; 

  //-------------------------------------------------------------------------//
  //    Matrix mult                                                          //
  //-------------------------------------------------------------------------//
  matrix_mult_9 #(
      .WIDTH            (WIDTH),
      .ACCUM_WIDTH      (ACCUM_WIDTH),
      .ARRAY_ACCUM_WIDTH(ARRAY_ACCUM_WIDTH),
      .Tm               (Tm),
      .Tn               (Tn),
      .Tk               (Tk),
      .M                (M),
      .N                (N),
      .K                (K),
      .W_SIZE           (W_SIZE),
      .I_SIZE           (I_SIZE),
      .O_SIZE           (O_SIZE)
  ) matrix_mult_0 (
      .clk_i                (g_clk                ),
      .rstn_i               (rstn_i               ),
      .start_i              (start_i              ),
      .data_config_i        (data_config_i        ),
      .ob_mem_cenb_R_o      (ob_mem_cenb_R_o      ),
      .ob_mem_wenb_R_o      (ob_mem_wenb_R_o      ),
      .ob_mem_addr_R_o      (ob_mem_addr_R_o      ),
      .ob_mem_data_R_o      (ob_mem_data_R_o_w    ),
      .ob_mem_data_R_i      (ob_mem_data_R_i_w    ),
      .ob_mem_cenb_W_o      (ob_mem_cenb_W_o      ),
      .ob_mem_wenb_W_o      (ob_mem_wenb_W_o      ),
      .ob_mem_addr_W_o      (ob_mem_addr_W_o      ),
      .ob_mem_data_W_o      (ob_mem_data_W_o_w    ),
      .ob_mem_data_W_i      (ob_mem_data_W_i_w    ),
      .ib_mem_cenb_o        (ib_mem_cenb_o        ),
      .ib_mem_wenb_o        (ib_mem_wenb_o        ),
      .ib_mem_addr_o        (ib_mem_addr_o        ),
      .ib_mem_data_i        (ib_mem_data_i_w      ),
      .wb_mem_cenb_o        (wb_mem_cenb_o        ),
      .wb_mem_wenb_o        (wb_mem_wenb_o        ),
      .wb_mem_addr_o        (wb_mem_addr_o        ),
      .wb_mem_data_i        (wb_mem_data_i_w      ),
      .ext_en_i             (ext_en_i             ),
      .ext_inputs_i         (ext_inputs_w         ),
      .ext_result_o         (ext_result_w         ),
      .ext_valid_o          (ext_valid_o_w        ),
      .done_o               (done_o               ),
      .extra_output_bits_o  (extra_output_bits_o  )
    );

  // dut bypass
  assign sa_dut_data_w  = ( dut_bypass_w ) ? { ext_input_w, ext_psum_w } : { {(WIDTH*Tm){1'b0}}, ext_result_w } ;
  assign sa_dut_valid_w = ( dut_bypass_w ) ? ext_valid_i_w : ext_valid_o_w ;
  // The final driver row is still valid when done rises. Delay stop through
  // that sampling edge and the array pipeline, so MISR includes the last row.
  localparam ARRAY_LATENCY = Tk + Tn - 1;
  logic bist_stop_source, bypass_stop, array_stop;
  assign bist_stop_source = ext_en_i && !driver_bypass_w &&
                            !driver_mode_w && driver_done_w;
  shift_buffer #(.DATA_WIDTH(1), .BUFFER_LENGTH(1)) u_bypass_stop (
      .clk_i(g_clk), .rstn_i(rstn_i),
      .data_i(bist_stop_source), .data_o(bypass_stop)
  );
  shift_buffer #(.DATA_WIDTH(1), .BUFFER_LENGTH(ARRAY_LATENCY+1)) u_array_stop (
      .clk_i(g_clk), .rstn_i(rstn_i),
      .data_i(bist_stop_source), .data_o(array_stop)
  );
  assign sa_stop_w = dut_bypass_w ? bypass_stop : array_stop;

  //-------------------------------------------------------------------------//
  //    Monitor                                                              //
  //-------------------------------------------------------------------------//
  signature_analyzer_9 #(.DATA_WIDTH (DRIVER_WIDTH) ) 
    monitor_0 (
      .clk_i        (g_clk          ),
      .rstn_i       (rstn_i         ),
      .bypass_i     (sa_mode_w      ),     
      .stop_i       (sa_stop_w      ),     
      .seed_i       (sa_seed_w      ),
      .dut_valid_i  (sa_dut_valid_w ),     
      .dut_data_i   (sa_dut_data_w  ),
      .valid_o      (sa_valid_w     ),
      .data_o       (sa_data_w      )
    );

  // signature analyzer bypass
  assign ext_result_o = (sa_bypass_w) ? sa_dut_data_w : sa_data_w ;
  assign ext_valid_o  = (sa_bypass_w) ? sa_dut_valid_w : sa_valid_w ;

endmodule
