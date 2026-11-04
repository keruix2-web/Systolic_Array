/******************************************************************************
 External control for one stationary weight tile (no memory accesses or tiling).
 Load Tk consecutive rows, bottom row first, with ext_weight_en_i high. The
 final row commits the weights. Activations may begin on the following cycle.
 Leave ext_weight_en_i low while streaming/draining. Wait for the last result
 before loading new weights or changing ext_en_i; reset aborts an operation.
 ext_psum is unused, as in the TA reference model.
******************************************************************************/
module external_controller #(
    parameter Tk = 4
) (
    input  logic clk_i,
    input  logic rstn_i,
    input  logic ext_en_i,
    input  logic ext_weight_en_i,
    input  logic ext_valid_i,
    output logic load_weight_o,
    output logic write_weight_o,
    output logic act_valid_o
);
    localparam COUNT_WIDTH = (Tk > 1) ? $clog2(Tk) : 1;
    logic [COUNT_WIDTH-1:0] weight_count_q;
    logic weights_ready_q;

    assign load_weight_o  = rstn_i && ext_en_i && ext_weight_en_i;
    assign write_weight_o = load_weight_o && (weight_count_q == Tk-1);
    assign act_valid_o    = rstn_i && ext_en_i && weights_ready_q &&
                            !ext_weight_en_i && ext_valid_i;

    always_ff @(posedge clk_i) begin
        if (!rstn_i || !ext_en_i) begin
            weight_count_q  <= '0;
            weights_ready_q <= 1'b0;
        end else if (load_weight_o) begin
            if (write_weight_o) begin
                weight_count_q  <= '0;
                weights_ready_q <= 1'b1;
            end else begin
                weight_count_q  <= weight_count_q + 1'b1;
                weights_ready_q <= 1'b0;
            end
        end else begin
            // An interrupted burst is invalid; a new burst starts at row Tk-1.
            weight_count_q <= '0;
        end
    end
endmodule
