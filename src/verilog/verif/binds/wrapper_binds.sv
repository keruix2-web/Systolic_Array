// Wrapper/BiST bindings, in addition to the shared core bindings.
bind matrix_mult_wrapper_9 matrix_mult_wrapper_checker #(
    .WIDTH(WIDTH), .Tm(Tm), .Tn(Tn), .DRIVER_WIDTH(DRIVER_WIDTH)
) u_wrapper_checker (.*);

bind matrix_mult_wrapper_9 bist_checker #(.Tk(Tk), .Tn(Tn))
    u_bist_checker (.*);

bind lfsr_9 lfsr_checker #(.NUM_BITS(NUM_BITS)) u_lfsr_checker (.*);
bind misr_9 misr_checker #(.NUM_BITS(NUM_BITS)) u_misr_checker (.*);
