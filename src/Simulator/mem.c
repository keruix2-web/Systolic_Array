#include <stdio.h>
#include <stdlib.h>
#include "mem.h"

// Number of hex digits used for each element in the matrix files (2 for 8 bit data)
#define HEX_DIGITS  ((OUT_WIDTH_BITS + 3) / 4)

/*
 * Crash the program if memory can't be allocated or a file can't be opened
*/
void fatal(const char *msg, const char *detail) {
    fprintf(stderr, "Error: %s%s%s\n", msg, detail ? ": " : "", detail ? detail : "");
    exit(EXIT_FAILURE);
}

int64_t sign_extend(uint64_t raw, int bits) {
    // Mask extracts just the used bits in the 64 bit int. Sign extracts only the sign bit
    uint64_t mask = (UINT64_C(1) << bits) - 1;
    uint64_t sign = UINT64_C(1) << (bits - 1);
    raw &= mask;
    // If the sign bit is set, turn it into the 64-bit twos complement
    return (raw & sign) ? (int64_t)raw - (int64_t)(mask + 1) : (int64_t)raw;
}

int64_t saturate(int64_t value, int bits) {
    // The range of a twos complement n bit number is -2^(n-1) to 2^(n-1)-1
    int64_t max = (INT64_C(1) << (bits - 1)) - 1;
    int64_t min = -(INT64_C(1) << (bits - 1));

    // Saturate value to the max or minimum value if needed, otherwise return original value
    if(value > max) return max;
    if(value < min) return min;
    return value;
}

matrix_t matrix_alloc(int rows, int cols) {
    matrix_t m;
    m.rows = rows;
    m.cols = cols;
    m.data = calloc((size_t)rows * cols, sizeof(int64_t));
    if(!m.data) fatal("failed to allocate matrix", NULL);
    return m;
}

void matrix_free(matrix_t *m) {
    free(m->data);
    m->data = NULL;
    m->rows = 0;
    m->cols = 0;
}

matrix_t matrix_load_file(const char *path, int rows, int cols) {
    FILE *f = fopen(path, "r");
    if(!f) fatal("could not open matrix file", path);

    matrix_t m = matrix_alloc(rows, cols);

    // Each element is a two's complement hex value (ex: FE = -2), separated by whitespace
    for(int i = 0; i < rows; i++){
        for(int j = 0; j < cols; j++){
            unsigned int raw;
            if(fscanf(f, "%x", &raw) != 1){
                fclose(f);
                fatal("matrix file has fewer elements than expected", path);
            }
            matrix_set(&m, i, j, sign_extend(raw, OUT_WIDTH_BITS));
        }
    }

    fclose(f);
    return m;
}

void matrix_write_file(const char *path, const matrix_t *m) {
    FILE *f = fopen(path, "w");
    if(!f) fatal("could not open output file", path);

    uint64_t mask = (UINT64_C(1) << OUT_WIDTH_BITS) - 1;

    // Write each row on its own line with elements separated by a space, matching doc/examples
    for(int i = 0; i < m->rows; i++){
        for(int j = 0; j < m->cols; j++){
            uint64_t raw = (uint64_t)matrix_get(m, i, j) & mask;
            fprintf(f, "%s%0*llX", j ? " " : "", HEX_DIGITS, (unsigned long long)raw);
        }
        fprintf(f, "\n");
    }

    fclose(f);
}

int64_t matrix_get(const matrix_t *m, int row, int col) {
    if(row < 0 || row >= m->rows || col < 0 || col >= m->cols){
        fprintf(stderr, "matrix_get out of bounds: (%d, %d) in %dx%d\n", row, col, m->rows, m->cols);
        exit(EXIT_FAILURE);
    }
    return m->data[row * m->cols + col];
}

void matrix_set(matrix_t *m, int row, int col, int64_t value) {
    if(row < 0 || row >= m->rows || col < 0 || col >= m->cols){
        fprintf(stderr, "matrix_set out of bounds: (%d, %d) in %dx%d\n", row, col, m->rows, m->cols);
        exit(EXIT_FAILURE);
    }
    m->data[row * m->cols + col] = value;
}

psum_mem_t psum_mem_alloc(int rows, int cols) {
    psum_mem_t p;
    p.rows = rows;
    p.cols = cols;
    // calloc so every partial sum starts at 0 before the first tile accumulates into it
    p.data = calloc((size_t)rows * cols, sizeof(int64_t));
    if(!p.data) fatal("failed to allocate partial sum memory", NULL);
    return p;
}

void psum_mem_free(psum_mem_t *p) {
    free(p->data);
    p->data = NULL;
    p->rows = 0;
    p->cols = 0;
}

int64_t psum_mem_get(const psum_mem_t *p, int row, int col) {
    if(row < 0 || row >= p->rows || col < 0 || col >= p->cols){
        fprintf(stderr, "psum_mem_get out of bounds: (%d, %d) in %dx%d\n", row, col, p->rows, p->cols);
        exit(EXIT_FAILURE);
    }
    return p->data[row * p->cols + col];
}

void psum_mem_accumulate(psum_mem_t *p, int row, int col, int64_t value) {
    if(row < 0 || row >= p->rows || col < 0 || col >= p->cols){
        fprintf(stderr, "psum_mem_accumulate out of bounds: (%d, %d) in %dx%d\n", row, col, p->rows, p->cols);
        exit(EXIT_FAILURE);
    }
    // Saturate the sums in the partial sum array to the amount of bits the memory can hold
    int64_t sum = p->data[row * p->cols + col] + value;
    p->data[row * p->cols + col] = saturate(sum, PSUM_WIDTH_BITS);
}
