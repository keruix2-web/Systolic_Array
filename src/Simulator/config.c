#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#include "config.h"

static int parse_positive_int(const char *s, int *out) {
    char *end;
    long val = strtol(s, &end, 10);
    if (s == end || *end != '\0' || val <= 0 || val > INT_MAX) {
        return -1;
    }
    *out = (int)val;
    return 0;
}

int config_parse_args(int argc, char **argv, sim_config_t *cfg) {
    if (argc != 9) {
        return -1;
    }

    if (parse_positive_int(argv[1], &cfg->PE_rows) != 0 ||
        parse_positive_int(argv[2], &cfg->PE_cols) != 0 ||
        parse_positive_int(argv[3], &cfg->M) != 0 ||
        parse_positive_int(argv[4], &cfg->N) != 0 ||
        parse_positive_int(argv[5], &cfg->K) != 0) {
        return -1;
    }

    cfg->a_path = argv[6];
    cfg->b_path = argv[7];
    cfg->c_path = argv[8];

    // It is required that K is a factor of the number of PE rows and 
    // N is a factor of the number of PE columns so that the weight
    // matrix can evenly be divided into the systolic array.
    // M must also be a multiple of the PE rows since activation tiles are PE_rows tall
    if (cfg->M % cfg->PE_rows != 0 || cfg->K % cfg->PE_rows != 0 || cfg->N % cfg->PE_cols != 0) {
        return -1;
    }

    return 0;
}

void config_print(const sim_config_t *cfg) {
    printf("Simulator configuration:\n");
    printf("  PE array:  %d x %d\n", cfg->PE_rows, cfg->PE_cols);
    printf("  GEMM dims: M=%d N=%d K=%d\n", cfg->M, cfg->N, cfg->K);
    printf("  A path: %s\n", cfg->a_path);
    printf("  B path: %s\n", cfg->b_path);
    printf("  C path: %s\n", cfg->c_path);
}
