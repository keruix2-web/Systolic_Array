#include <stdlib.h>
#include "systolic.h"

systolic_array_t *systolic_create(int rows, int cols) {
    systolic_array_t *new_systolic_array = calloc(1, sizeof(*new_systolic_array));
    if(!new_systolic_array) return NULL;

    new_systolic_array->rows = rows;
    new_systolic_array->cols = cols;
    new_systolic_array->cycle_count = 0;
    new_systolic_array->array = calloc(rows, sizeof(pe_t *));
    if(!new_systolic_array->array){
        free(new_systolic_array);
        return NULL;
    }

    for(int i = 0; i < rows; i++){
        new_systolic_array->array[i] = calloc(cols, sizeof(pe_t));
        if(!new_systolic_array->array[i]){
            for(int k = 0; k < i; k++){
                free(new_systolic_array->array[k]);
            }
            free(new_systolic_array->array);
            free(new_systolic_array);
            return NULL;
        }

        for(int j = 0; j < cols; j++){
            pe_init(&new_systolic_array->array[i][j], i, j);
        }
    }

    return new_systolic_array;
}

void systolic_destroy(systolic_array_t *arr) {
    // Free every row in the array structure first since each row is a pointer to a list
    for(int i = 0; i < arr->rows; i++){
        free(arr->array[i]);
    }

    free(arr->array);
    free(arr);
}

void systolic_reset(systolic_array_t *arr) {
    arr->cycle_count = 0;

    for(int i = 0; i < arr->rows; i++){
        for(int j = 0; j < arr->cols; j++){
            pe_reset(&arr->array[i][j]);
        }
    }
}

void systolic_load_weight_tile(systolic_array_t *arr, const matrix_t *B, int tile_row_start, int tile_col_start) {
    for(int i = 0; i < arr->rows; i++){
        for(int j = 0; j < arr->cols; j++){
            pe_load_weight(&arr->array[i][j], matrix_get(B, tile_row_start + i, tile_col_start + j));
        }
    }

    // In hardware, the weights are loaded in row-by-row, so this takes row cycles
    arr->cycle_count += arr->rows;
}

void systolic_step(systolic_array_t *arr, const int64_t *west_in, const int64_t *north_in, int64_t *south_out) {
    // Cycle each PE, starting at the bottom right and working our way left and up
    // This ensures the output from the previous cycle of the west/north PE is used (not the output from the current cycle)
    for(int i = arr->rows-1; i >=0; i--){
        // For the top row of PEs (i=0), get the partial sum from the north (from memory for GEMM or 0)
        if(i == 0){
            for(int j = arr->cols-1; j > 0; j--){
                // Use the activation from the PE to the west (one column before)
                // Use the partial sum from the PE to the north (one row above)
                pe_cycle(&arr->array[0][j], arr->array[0][j-1].act_out, north_in[j]);
            }

            // For the top left corner, both activation and partial sum come from input to the systolic array unit
            pe_cycle(&arr->array[0][0], west_in[0], north_in[0]);

        }else{
            for(int j = arr->cols-1; j > 0; j--){
                // Use the activation from the PE to the west (one column before)
                // Use the partial sum from the PE to the north (one row above)
                pe_cycle(&arr->array[i][j], arr->array[i][j-1].act_out, arr->array[i-1][j].psum_out);
            }

            // For the leftmost column of PEs (j=0), get the activation from the call of this function (west_in)
            pe_cycle(&arr->array[i][0], west_in[i], arr->array[i-1][0].psum_out);
        }
    }

    // Write the partial sums of the bottom row of PEs out
    for(int j = 0; j < arr->cols; j++){
        south_out[j] = arr->array[arr->rows - 1][j].psum_out;
    }

    // Increment the cycle count
    arr->cycle_count++;
}

void systolic_run_tile(systolic_array_t *arr, const matrix_t *act_tile, psum_mem_t *psum_mem, int out_tile_row, int out_tile_col) {
    int R = arr->rows;
    int C = arr->cols;
    int M = act_tile->rows;

    // Memory location of this tile's top left corner in the partial sum memory
    int row_offset = out_tile_row * M;
    int col_offset = out_tile_col * C;
    
    // Create an array to hold the output from the systolic array
    int64_t *output = calloc(C, sizeof(int64_t));

    // Create an array to hold the activation input column
    int64_t *act_col = calloc(R, sizeof(int64_t));

    // Create an array of 0s for the partial sum input since we are accumulating partial sums in place in memory
    int64_t *psum_row = calloc(C, sizeof(int64_t));

    // The last output (created when the last input activation row and last weight in the last weight column are multiplied)
    // is generated at step M + R + C - 3, so M + R + C - 2 steps are needed
    int total_steps = M + R + C - 2;
    for(int t = 0; t < total_steps; t++){
        // Skew the input activations so row i starts getting fed at cycle i
        for(int i = 0; i < R; i++){
            if(t >= i && t-i < M){
                act_col[i] = matrix_get(act_tile, t-i, i);
            }else{
                act_col[i] = 0;
            }
        }

        systolic_step(arr, act_col, psum_row, output);

        // Save the output as the final output arrives at the south end
        // Column j finishes C[m][j] at step t = i + (R-1) + j
        for(int j = 0; j < C; j++){
            if(t >= (R-1) + j && t < (R-1) + j + M){
                psum_mem_accumulate(psum_mem, row_offset + (t-((R-1)+j)), col_offset + j, output[j]);
            }
        }
    }    

    // Free the arrays created for this function
    free(output);
    free(act_col);
    free(psum_row);
}

void systolic_run_gemm(systolic_array_t *arr, const sim_config_t *cfg, const matrix_t *A, const matrix_t *B, matrix_t *C) {
    int rows = arr->rows;
    int cols = arr->cols;

    int k_tiles = cfg->K / rows;
    int n_tiles = cfg->N / cols;

    // Create the partial sum memory that will hold intermediary results (same shape as the output C)
    psum_mem_t psum = psum_mem_alloc(cfg->M, cfg->N);

    // Create a buffer to hold the current activation strip (all M rows of one K tile)
    matrix_t act_strip = matrix_alloc(cfg->M, rows);

    for(int n = 0; n < n_tiles; n++){
        for(int k = 0; k < k_tiles; k++){
            // Each weight tile should only be loaded into the systolic array once
            systolic_load_weight_tile(arr, B, k*rows, n*cols);

            // Like the RTL, stream all M rows of this K column strip back to back instead of one
            // M tile at a time. Each activation row only produces its own output row, so the results
            // are the same, but the array fills and drains once per weight tile instead of once per M tile
            for(int i = 0; i < cfg->M; i++){
                for(int j = 0; j < rows; j++){
                    matrix_set(&act_strip, i, j, matrix_get(A, i, k*rows + j));
                }
            }
            systolic_run_tile(arr, &act_strip, &psum, 0, n);
        }
    }

    // Now all of the fully accumulated values must be saturated to the output bit width
    for(int i = 0; i < cfg->M; i++){
        for(int j = 0; j < cfg->N; j++){
            matrix_set(C, i, j, saturate(psum_mem_get(&psum, i, j), OUT_WIDTH_BITS));
        }
    }

    // Free arrays created for this function
    matrix_free(&act_strip);
    psum_mem_free(&psum);
}
