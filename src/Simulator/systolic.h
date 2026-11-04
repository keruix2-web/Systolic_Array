#ifndef SYSTOLIC_H
#define SYSTOLIC_H

#include "config.h"
#include "PE.h"
#include "mem.h"

/*
 * Array of PEs to represent the systolic array
 */
typedef struct {
    int     rows, cols;
    pe_t    **array;
    long    cycle_count;        // Total number of cycles simulated for debugging
} systolic_array_t;

systolic_array_t    *systolic_create(int rows, int cols);
void                systolic_destroy(systolic_array_t *arr);
void                systolic_reset(systolic_array_t *arr);

/* 
 * Load all of the weights in matrix B into the PEs of the systolic array
 * Increment cycle count by row because in hardware, one row is scanned in at a time
 */
void systolic_load_weight_tile(systolic_array_t *arr, const matrix_t *B, int tile_row_start, int tile_col_start);

/*
 * Advances every PE in the grid by one clock cycle, advancing data along the path accordingly
 *   west_in[rows]      activation entering each row from the west edge
 *   north_in[cols]     partial sum entering each column from the north edge
 *   south_out[cols]    partial sum exiting each column at the south edge (output)
 */
void systolic_step(systolic_array_t *arr, const int64_t *west_in, const int64_t *north_in, int64_t *south_out);

/*
 * Streams one (M_tile x K_tile) activation tile through the already-loaded
 * weight tile, handling the pipeline skew/drain cycles a systolic array
 * needs, and accumulates the resulting (M_tile x N_tile) partial-sum tile
 * into psum_mem at [out_tile_row, out_tile_col].
 */
void systolic_run_tile(systolic_array_t *arr, const matrix_t *act_tile, psum_mem_t *psum_mem, int out_tile_row, int out_tile_col);

/*
 * Top-level tiled GEMM driver (the "Memory mode" controller behavior):
 * loops over all N/K tiles, calling systolic_load_weight_tile and then
 * systolic_run_tile once with all M activation rows of that K strip (like
 * the RTL, there is no separate M tile loop), then saturates the
 * fully-accumulated partial sums down into the int8 output matrix C.
 */
void systolic_run_gemm(systolic_array_t *arr, const sim_config_t *cfg, const matrix_t *A, const matrix_t *B, matrix_t *C);

#endif /* SYSTOLIC_H */
