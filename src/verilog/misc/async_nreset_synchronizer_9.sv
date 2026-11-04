module async_nreset_synchronizer_9 (
    input  logic clk_i,
    input  logic async_nreset_i,
    output logic rstn_o
    );

    logic r_sync;

    always_ff @(posedge clk_i or negedge async_nreset_i) begin
        if (!async_nreset_i) begin
            {rstn_o, r_sync} <= 2'b00;
        end else begin
            {rstn_o, r_sync} <= {r_sync,1'b1};
        end
    end

endmodule