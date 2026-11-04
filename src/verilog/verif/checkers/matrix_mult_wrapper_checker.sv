`include "mm_verif_defs.svh"

module matrix_mult_wrapper_checker
    import matrix_mult_pkg::*;
    #(parameter WIDTH=8, Tm=4, Tn=4, DRIVER_WIDTH=64) (
    input logic g_clk, rstn_i,
    input test_config_struct test_config_i,
    input external_inputs_struct ext_inputs_i, ext_inputs_w,
    input logic driver_bypass_w, dut_bypass_w, sa_bypass_w, driver_mode_w, sa_mode_w,
    input logic [Tm-1:0][WIDTH-1:0] ext_input_w,
    input logic [Tn-1:0][WIDTH-1:0] ext_psum_w, ext_result_w,
    input logic ext_valid_i_w, ext_valid_o_w,
    input logic [DRIVER_WIDTH-1:0] driver_data_w, sa_dut_data_w, sa_data_w, ext_result_o,
    input logic driver_valid_o_w, sa_dut_valid_w, sa_valid_w, ext_valid_o
);
    default clocking cb @(posedge g_clk); endclocking
    default disable iff (!rstn_i);
    a_config: assert property ({sa_bypass_w,dut_bypass_w,driver_bypass_w} == test_config_i.bypass &&
                              {sa_mode_w,driver_mode_w} == test_config_i.mode)
        else `SVA_FAIL("wrapper configuration mapping mismatch")
    a_driver_data: assert property ({ext_input_w,ext_psum_w} ==
        (driver_bypass_w ? {ext_inputs_i.ext_input,ext_inputs_i.ext_psum} : driver_data_w))
        else `SVA_FAIL("wrapper driver data mux mismatch")
    a_driver_valid: assert property (ext_valid_i_w ==
        (driver_bypass_w ? ext_inputs_i.ext_valid : driver_valid_o_w))
        else `SVA_FAIL("wrapper driver valid mux mismatch")
    a_weights_direct: assert property (ext_inputs_w.ext_weight == ext_inputs_i.ext_weight &&
        ext_inputs_w.ext_weight_en == ext_inputs_i.ext_weight_en)
        else `SVA_FAIL("wrapper changed external weight loading")
    a_core_inputs: assert property ({ext_inputs_w.ext_input,ext_inputs_w.ext_psum,ext_inputs_w.ext_valid} ==
        {ext_input_w,ext_psum_w,(ext_valid_i_w && !dut_bypass_w)})
        else `SVA_FAIL("wrapper core input packing mismatch")
    a_dut_data: assert property (sa_dut_data_w == (dut_bypass_w ?
        {ext_input_w,ext_psum_w} : {{(WIDTH*Tm){1'b0}},ext_result_w}))
        else `SVA_FAIL("wrapper DUT bypass or result packing mismatch")
    a_dut_valid: assert property (sa_dut_valid_w == (dut_bypass_w ? ext_valid_i_w : ext_valid_o_w))
        else `SVA_FAIL("wrapper DUT valid mux mismatch")
    a_monitor_data: assert property (ext_result_o == (sa_bypass_w ? sa_dut_data_w : sa_data_w))
        else `SVA_FAIL("wrapper monitor data mux mismatch")
    a_monitor_valid: assert property (ext_valid_o == (sa_bypass_w ? sa_dut_valid_w : sa_valid_w))
        else `SVA_FAIL("wrapper monitor valid mux mismatch")
    covergroup cg_paths @(posedge g_clk iff rstn_i);
        cp_bypass: coverpoint test_config_i.bypass { bins paths[] = {[0:7]}; }
        cp_modes: coverpoint test_config_i.mode { bins modes[] = {[0:3]}; }
        x_paths: cross cp_bypass, cp_modes;
    endgroup
    cg_paths cg_paths_inst = new();
endmodule
