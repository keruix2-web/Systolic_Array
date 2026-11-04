`ifndef __MATRIX_MULT_PKG__
`define __MATRIX_MULT_PKG__

package matrix_mult_pkg;

localparam WIDTH    = 8;
localparam ROW      = 4;
localparam COL      = 4;
localparam W_SIZE   = 1024;
localparam I_SIZE   = 1024;
localparam O_SIZE   = 1024;

localparam MAX_ROW  = 64;
localparam MAX_COL  = 64;
localparam EXTRA_INPUT_SCAN_BITS = 4;     //misc input static bits for students to use
localparam EXTRA_OUTPUT_SCAN_BITS = 8;     //misc output static bits for students to use

localparam INPUT_DATA_WIDTH = WIDTH * ROW;
localparam WEIGHT_DATA_WIDTH = WIDTH * COL;

localparam DRIVER_WIDTH  = WIDTH * ( ROW + COL );

typedef struct packed{
    logic [$clog2(MAX_ROW+1)-1:0]  w_rows;            // weights matrix rows
    logic [$clog2(MAX_COL+1)-1:0]  w_cols;            // weights matrix columns
    logic [$clog2(MAX_ROW+1)-1:0]  i_rows;            // inputs matrix rows
    logic [$clog2(W_SIZE)-1:0]   w_offset;          // weights memory offset
    logic [$clog2(I_SIZE)-1:0]   i_offset;          // inputs memory offset
    logic [$clog2(O_SIZE)-1:0]   psum_offset;       // partial sums memory offset
    logic [EXTRA_INPUT_SCAN_BITS-1:0]       extra_config_i;      // extra configuration bits student-defined scan signals
} data_config_struct;

typedef struct packed{
    logic [EXTRA_OUTPUT_SCAN_BITS-1:0] extra_config_o;  //extra output bits for student-defined scan signals
} extra_output_bits_struct;

typedef struct packed{
    logic [2:0]                  bypass;            // bypasses
    logic [1:0]                  mode;              // modes
    logic                        driver_valid;      // driver valid bit
    logic [DRIVER_WIDTH-1:0]     driver_stop_code;  // driver stop code
} test_config_struct;

typedef struct packed{
    logic                        ext_weight_en;     // external weights push enable
    logic [ROW-1:0][WIDTH-1:0]   ext_input;         // external inputs
    logic                        ext_valid;         // external valid input
    logic [COL-1:0][WIDTH-1:0]   ext_weight;        // external weights
    logic [COL-1:0][WIDTH-1:0]   ext_psum;          // external partial sums    //TA Note: TA model does not contain support for ext_psum
} external_inputs_struct;

endpackage

`endif