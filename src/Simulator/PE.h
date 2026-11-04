#ifndef PE_H
#define PE_H

#include "config.h"

/*
 * Structure to hold values of the weight-stationary PE
 */
typedef struct {
    int64_t weight;
    int64_t act_out;
    int64_t psum_out;
    int     row, col;       // Position within systolic array for debugging
} pe_t;

void pe_init(pe_t *pe, int row, int col);
void pe_reset(pe_t *pe);

/* 
 * Loads in the stationary weight (matrix B)
*/
void pe_load_weight(pe_t *pe, int64_t weight);

/*
 * Advances this PE by one clock cycle:
 * get a new input activation from the west and partial sum from the north
 * compute the updted partial sum (psum_in + weight * act_in)
 * Save the new partial sum and activation to act_out and psum_out
 */
void pe_cycle(pe_t *pe, int64_t act_in, int64_t psum_in);

#endif
