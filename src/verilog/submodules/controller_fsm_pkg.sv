package controller_fsm_pkg;
typedef enum logic [2:0] {
    IDLE = 3'b000,
    LOAD_WEIGHT = 3'b001,
    STREAM = 3'b010,
    DRAIN = 3'b011,
    DONE = 3'b100,
    STATEX = 3'bxxx
} state_struct;
endpackage