#ifndef MEM_H
#define MEM_H

#include "config.h"

/*
 * Dense matrix of OUTPUT_WIDTH_BITS precision elements stored in row-major.
 * Used for the A (activation), B (weight), and final C (output) matrices
 * that are read from / written to the input/output files.
 */
typedef struct {
    int     rows, cols;
    int64_t *data;
} matrix_t;

/*
 * Partial-sum matrix with PSUM_WIDTH_BITS precision (saturated)
 * Shape matches the output matrix (M x N)
 */
typedef struct {
    int     rows, cols;
    int64_t *data;
} psum_mem_t;

/*
 * Print an error message and exit
 */
void        fatal(const char *msg, const char *detail);

matrix_t    matrix_alloc(int rows, int cols);
void        matrix_free(matrix_t *m);

/*
 * Interpret the low bits of raw as a two's complement number
 */
int64_t     sign_extend(uint64_t raw, int bits);

/*
 * Clamp value to the range of a signed bits-wide integer
 * Used for PSUM_WIDTH_BITS partial sums and the final OUT_WIDTH_BITS output
 */
int64_t     saturate(int64_t value, int bits);

/* 
 * Reads a rows x cols matrix from the given file path
*/
matrix_t    matrix_load_file(const char *path, int rows, int cols);

/* 
 * Writes m out to the file given by path in the same format as input 
*/
void        matrix_write_file(const char *path, const matrix_t *m);

/* 
 * row and col accessors that check bounds and implement indexing scheme
 */
int64_t     matrix_get(const matrix_t *m, int row, int col);
void        matrix_set(matrix_t *m, int row, int col, int64_t value);

psum_mem_t  psum_mem_alloc(int rows, int cols);
void        psum_mem_free(psum_mem_t *p);
int64_t     psum_mem_get(const psum_mem_t *p, int row, int col);

/* 
 * Accumulate value into p[row][col], saturating to signed PSUM_WIDTH_BITS
*/
void        psum_mem_accumulate(psum_mem_t *p, int row, int col, int64_t value);

#endif
