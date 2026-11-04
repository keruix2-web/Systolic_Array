package pseudo_rand_num_gen_pkg;
typedef enum logic[1:0] {
    IDLE    = 2'b00,
    RUN     = 2'b01,
    DONE    = 2'b10
} st_prng_state;
endpackage