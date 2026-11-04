#include "PE.h"

void pe_init(pe_t *pe, int row, int col) {
    pe->row = row;
    pe->col = col;
    
    pe->weight = 0;
    pe->act_out = 0;
    pe->psum_out = 0;
}

void pe_reset(pe_t *pe) {
    pe->weight = 0;
    pe->act_out = 0;
    pe->psum_out = 0;
}

void pe_load_weight(pe_t *pe, int64_t weight) {
    pe->weight = weight;
}

void pe_cycle(pe_t *pe, int64_t act_in, int64_t psum_in) {
    // During each cycle, put the new activation and partial sum on the output
    pe->act_out = act_in;
    // Internally, partial sums are full precision (18 bits is large enough for full precision in a 4x4 array)
    pe-> psum_out = psum_in + pe->weight * act_in;
}
