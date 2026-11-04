task initialize_signals();
   begin
      rstn_async_i        = 1'b0;
      start_i             = '0;
      w_rows_i            = '0;
      w_cols_i            = '0;
      i_rows_i            = '0;
      w_offset            = '0;
      i_offset            = '0;
      psum_offset_r       = '0;

      ob_mem_data_i       = '0;
      ib_mem_data_i       = '0;
      wb_mem_data_i       = '0;
      ps_mem_data_i       = '0;

      ext_en_i            = '0;
      ext_input_i         = '0;
      ext_weight_i        = '0;
      ext_psum_i          = '0;
      ext_weight_en_i     = '0;
   
      bypass_i            = '1;
      mode_i              = '1;
      driver_valid_i      = '0;
      driver_stop_code_i  = '0;
   end
endtask

task reset_signals();
   begin
      repeat (10) @(posedge i_clk);
      initialize_signals();
   end
endtask

task external_mode();
   begin
      reset_signals();
        
      @(posedge i_clk);

      // SET CONTROL SIGNALS
      
      rstn_async_i =  1'b1;

      // LOAD WEIGHTS

      // STREAM INPUTS AND PARTIAL SUMS

      // COMPARE RESULTS
      

    end
endtask

task memory_mode();
   begin
      reset_signals();
        
      @(posedge i_clk);

      // SET CONTROL SIGNALS
      
      rstn_async_i =  1'b1;

      // LOAD MEMORIES

      @(negedge clk_i);
      start_i  = '1;
      @(negedge clk_i);
      start_i  = '0;
      @(posedge done_o);

      // COMPARE RESULTS

    end
endtask

task bist_mode();
   begin
      reset_signals();
        
      @(posedge i_clk);

      // SET CONTROL SIGNALS

      rstn_async_i =  1'b1;

      // LOAD WEIGHT BUFFERS WITH EXTERNAL MODE

      rstn_async_i =  1'b0;

      // SET CONTROL SIGNALS
      // SET STOP CODE
      
      rstn_async_i =  1'b1;

      // CHECK RESULTS

    end
endtask
