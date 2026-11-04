/******************************************************************************
 File Name : mm_binds.sv
 Description :
     Attaches the verification checkers to the RTL without modifying it.
     Every instance of each module gets its own checker, and .* connects
     the checker ports to the same-named ports and internal signals of the
     target module. Parameters are taken from the bound instance.

     Leave this file out of the file list (tb_matrix_mult.include) to
     simulate without assertions or functional coverage, e.g. for a
     post-synthesis netlist where the internal signals no longer exist.
*******************************************************************************/

bind matrix_mult_9 matrix_mult_checker #(
    .WIDTH              (WIDTH),
    .ACCUM_WIDTH        (ACCUM_WIDTH),
    .ARRAY_ACCUM_WIDTH  (ARRAY_ACCUM_WIDTH),
    .Tm                 (Tm),
    .Tn                 (Tn),
    .Tk                 (Tk),
    .W_SIZE             (W_SIZE),
    .I_SIZE             (I_SIZE),
    .O_SIZE             (O_SIZE)
) u_matrix_mult_checker (.rstn_i(mem_rstn), .*);

bind controller controller_checker #(
    .Tn                 (Tn),
    .Tk                 (Tk),
    .W_SIZE             (W_SIZE),
    .I_SIZE             (I_SIZE),
    .O_SIZE             (O_SIZE)
) u_controller_checker (.*);

bind systolic_array systolic_array_checker #(
    .INPUT_WIDTH        (INPUT_WIDTH),
    .ARRAY_W            (ARRAY_W),
    .ARRAY_H            (ARRAY_H),
    .ACCUM_WIDTH        (ACCUM_WIDTH)
) u_systolic_array_checker (.*);

bind PE PE_checker #(
    .ACT_WIDTH          (ACT_WIDTH),
    .WEIGHT_WIDTH       (WEIGHT_WIDTH),
    .INTERNAL_SUM_WIDTH (INTERNAL_SUM_WIDTH)
) u_PE_checker (.*);

bind shift_buffer shift_buffer_checker #(
    .DATA_WIDTH         (DATA_WIDTH),
    .BUFFER_LENGTH      (BUFFER_LENGTH)
) u_shift_buffer_checker (.*);

bind saturate saturate_checker #(
    .INPUT_WIDTH        (INPUT_WIDTH),
    .OUTPUT_WIDTH       (OUTPUT_WIDTH)
) u_saturate_checker (.*);

bind external_controller external_controller_checker #(.Tk(Tk))
    u_external_controller_checker (.*);
bind matrix_mult_9 matrix_mult_external_checker #(
    .WIDTH(WIDTH), .Tm(Tm), .Tn(Tn), .Tk(Tk)
) u_matrix_mult_external_checker (.*);

bind debug_obs debug_obs_checker #(
    .WIDTH              (WIDTH),
    .Tn                 (Tn),
    .Tk                 (Tk)
) u_debug_obs_checker (.*);
