#include <stdio.h>
#include <stdlib.h>

#include "config.h"
#include "mem.h"
#include "systolic.h"

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s <rows> <cols> <M> <N> <K> <A path> <B path> <C path>\n",
        prog);
}

int main(int argc, char **argv) {
    sim_config_t cfg;

    // Print  out an instructional usage message if the wrong arguments are provided
    if (config_parse_args(argc, argv, &cfg) != 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    // Load in the matrices from the supplied files and allocate space for the output matrix
    matrix_t A = matrix_load_file(cfg.a_path, cfg.M, cfg.K);
    matrix_t B = matrix_load_file(cfg.b_path, cfg.K, cfg.N);
    matrix_t C = matrix_alloc(cfg.M, cfg.N);

    systolic_array_t *arr = systolic_create(cfg.PE_rows, cfg.PE_cols);
    if(!arr) fatal("failed to allocate systolic array", NULL);

    systolic_run_gemm(arr, &cfg, &A, &B, &C);
    matrix_write_file(cfg.c_path, &C);

    // Free all memory before quitting
    systolic_destroy(arr);
    matrix_free(&A);
    matrix_free(&B);
    matrix_free(&C);

    return EXIT_SUCCESS;
}
