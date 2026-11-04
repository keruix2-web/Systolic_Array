#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>

// Make the bit widths configurable in case of spec changes
#define OUT_WIDTH_BITS      8
#define PSUM_WIDTH_BITS     16     // Width of partial sums saved to memory

// Take the simulation properties that will be passed in from run.sh
typedef struct {
    int PE_rows;
    int PE_cols;
    int M;
    int N;
    int K;
    const char *a_path;
    const char *b_path;
    const char *c_path;
} sim_config_t;

/*
 * Parse argv from run.sh into a sim_config struct and return 0 on success
*/
int  config_parse_args(int argc, char **argv, sim_config_t *cfg);

/*
 * Print out the configuration for debug purposes
*/
void config_print(const sim_config_t *cfg);

#endif
