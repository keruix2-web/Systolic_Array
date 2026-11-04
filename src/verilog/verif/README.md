# matrix_mult Verification (memory mode with tiling)

## Running

From `sim/behav`:

```
make                           # same as make vcs: link sources, generate golden data, compile + run with coverage
make vcs TEST=rand_full_0      # run one test from tests.list (plus the directed tests)
make cov_report                # coverage report in urgReport/dashboard.html
make golden NUM_RANDOM=50 SEED=7   # only regenerate the test vectors
make external                  # core-only external mode (tb_matrix_mult_external)
make wrapper TB=tb_matrix_mult_wrapper_bist   # one wrapper-level testbench
make regress                   # every testbench below, then a PASS/FAIL summary
```

The memory run ends with `TB RESULT: PASSED` or `TB RESULT: FAILED`. A run passes only when every test matches its golden output, no assertion or scoreboard check failed, and the C simulator agrees with the SV reference model.

`make regress` runs all six testbenches. A failing one does not stop the rest. A testbench counts as passed only if its log has its PASSED line, so compile errors and crashes show up as FAIL. The run ends with `REGRESSION: ALL PASSED` or `REGRESSION: FAILED`.

| Testbench | Covers | PASSED line |
|---|---|---|
| `tb_matrix_mult` | Memory mode: golden and directed tests, including tiling | `TB RESULT: PASSED` |
| `tb_matrix_mult_external` | Core external mode | `EXTERNAL CORE PASSED` |
| `tb_matrix_mult_wrapper_external` | Direct external mode through the wrapper | `WRAPPER DIRECT EXTERNAL PASSED` |
| `tb_matrix_mult_wrapper_registered` | External mode through the driver and monitor registers | `WRAPPER REGISTERED EXTERNAL PASSED` |
| `tb_matrix_mult_wrapper_bist` | LFSR to MISR loopback, core bypassed | `WRAPPER BIST LOOPBACK PASSED` |
| `tb_matrix_mult_wrapper_full_bist` | BiST through the array, checked against an independent golden signature | `WRAPPER FULL BIST PASSED` |

Each testbench writes `<TB>.log` and `<TB>_compile.log`. The wrapper testbenches compile from `tb_matrix_mult_wrapper.include`, which binds all core and wrapper checkers.

## Flow

```
scripts/gen_golden.py ──► src/Simulator/run.sh (golden model)
        │                       │
        ▼                       ▼
 tests/<name>/A.txt, B.txt  C_golden.txt ──► cross-checked against a pure-Python model
 tests/<name>/ACT_MEM.hex, WEIGHT_MEM.hex, OUTPUT_MEM.hex, golden.log
 tests/tests.list
        │
        ▼
 tb_matrix_mult ── $readmemh into the memory emulators, pulse start_i, wait for done_o
        │          compare output memory vs OUTPUT_MEM.hex and an SV reference model
        ▼
 tests/<name>/dut.log  (same format as golden.log: diff tests/<name>/{golden,dut}.log)
```

The hex files use the tiled layout from the main README: one tile row (4 elements) per word (8 bits per element in `ACT_MEM.hex`/`WEIGHT_MEM.hex`, 16-bit sign-extended lanes in `OUTPUT_MEM.hex`, as the output memory stores them), lowest column in the LSBs, and each 4-wide column strip stored as a contiguous block of words. With K = N = 4 this is the `doc/examples/milestone_1b` format, and the generator checks that `ta_example` reproduces those files exactly. `tests.list` has one `<name> <M> <N> <K>` line per test. `gen_golden.py --no-tiling` generates only the single-tile (milestone 1b) set.

## Test set (147 golden tests + directed tests)

| Group | What it targets |
|---|---|
| `ta_example` | The TA example (identity × B) |
| `zeros_*`, `identity_B`, `perm_A_shift*`, `lane_order` | Lane/row routing, transposition, ordering |
| `all_max`, `all_min`, `min_x_max`, `max_x_min`, `checkerboard` | 18-bit internal sums (±65536) and output saturation |
| `sat_boundary*` | Exactly 127, 128, -128, -129 in every lane |
| `corner_aXX_bYY` (49) | Every (activation, weight) corner pair in every PE |
| `rand_small/med/full/sparse_*` | Random data; `small` never saturates, so every bit is checked |
| `stream_M{8,16,36,64}_*` | Longer activation streams (`i_rows` up to 64) |
| `tile_M*_K*_N*_{small,full,med}` | Tiling: N loop only, K accumulation only, both, up to 64 tiles in one dimension, and non-square shapes |
| `tile_identity_A`, `tile_perm_A`, `tile_lane_order` | Routing across strips (wrong strip or tile offsets show up as moved values) |
| `accum_cancel` | Two K tiles that each saturate 8 bits but sum to 0 (partial sum must keep 16 bits) |
| `psum_sat16_*` | 16-bit partial sum saturation between K tiles changes the final sign |
| `tile_max_64x64x64_*` | Largest shape (fills every memory) |
| `tile_rand_*` | Random shapes, every dimension a multiple of 4 up to 64 |

The first 113 tests are the milestone 1b set and generate the same files as before.

Directed tests (in `tb_matrix_mult_tasks.sv`):

| Test | What it checks |
|---|---|
| `start_held_high` | `start_i` held high for the whole run and after it; `done_o` stays high |
| `start_multi_cycle` | `start_i` held high for 5 cycles |
| `restart_from_done*` | New data and a new start edge from DONE, without a reset |
| `nonzero_offsets`, `offsets_at_top_of_memory` | `i_offset`, `w_offset`, `psum_offset` |
| `tiled_start_held_high` | `start_i` held high through a multi-tile run (no restart between tiles) |
| `tiled_then_single_tile`, `single_tile_then_tiled`, `tiled_restart_*` | Restart from DONE with a different shape (tile counters and offsets reset) |
| `tiled_nonzero_offsets`, `tiled_offsets_at_top_of_memory` | Offsets with several strips per memory |
| `reset_sweep` | Reset in every cycle of a run (all FSM states), then a clean run. Done for a single-tile run and an 8x8x8 run (4 tiles), so reset also lands in the DRAIN to LOAD_WEIGHT tile transitions |
| `start_high_through_reset` | `start_i` already high when reset is released (not a rising edge, so the DUT must not start) |
| `debug_obs_pages` | Debug add-on. Steps `extra_config_i` every cycle during `psum_sat16_pos` (3 K tiles, saturates 16 and 8 bits), and the results must still match. Then reads every page in DONE without a clock edge and compares it with values computed from the test: status, counters, row counts, the checksum of the last weight tile, and the saturation flags from the SV reference. Repeats after a restart from DONE with `rand_small_0` (flags and counts cleared by the start edge) and checks that reset clears everything |

Every test also checks that `done_o` stays high, that each 16-bit output lane is the sign extension of the 8-bit result, and that no output word outside `[psum_offset, psum_offset + M*N/4)` was written. The SV reference model accumulates across K tiles with 16-bit saturation, the same as the C simulator.

## Assertions and coverage (bound with `mm_binds.sv`)

| Checker | Bound to | Main checks | Coverage |
|---|---|---|---|
| `matrix_mult_checker` | `matrix_mult` | Memory port protocol, no access before start or after done, start on a rising edge only, done latency (per shape)/hold/clear, read/write counts per run, read and write windows, writes in tile order, sign extension of final outputs | Pre-saturation value and 8-bit output per lane; 16-bit partial sum saturation; start/done handshake and tiled-run cases |
| `controller_checker` | `controller` | Edge detector, legal FSM transitions (including DRAIN to LOAD_WEIGHT), LOAD = Tk cycles, STREAM = i_rows cycles, tile base addresses from its own K/N tile model, read address order, 1-cycle control alignment, partial sum read and delayed write to the same address, `first_k_o`/`last_k_o` | States, transitions, reset in each state, `i_rows`, K and N tile counts |
| `systolic_array_checker` | `systolic_array` | Scoreboard: weight load model + full-precision expected row for every activation row; valid latency H+W-1; `weight_xor_o` = XOR of the modeled weights | psum magnitude (beyond 8/16 bits) per lane |
| `PE_checker` | every `PE` | MAC, pass-through, weight hold/write, no overflow | weight × activation corner cross, per instance |
| `shift_buffer_checker` | every `shift_buffer` | Output = input delayed by `BUFFER_LENGTH` | — |
| `saturate_checker` | every `saturate` | Output = input clamped to `OUTPUT_WIDTH`; `sat_o` high exactly when it clamps | (in `matrix_mult_checker`) |
| `debug_obs_checker` | `debug_obs` | Own model of the counters and sticky flags; `obs_o` equals the selected page in every cycle, also between clock edges (the mux is not registered) | Every `obs_sel` in memory and external mode, every flag set, flags cleared by start, counter wrap, external saturation |
| `tb_matrix_mult_tasks.sv` | testbench | Golden + SV reference comparison | Operand corner cross, run configuration |

To simulate a netlist (no internal signals), leave `mm_binds.sv` and the checker files out of the file list.


## External mode and wrapper integration

`make external` in `sim/behav` runs the core-only external regression with
bound checkers. `make wrapper TB=<name>` runs one wrapper testbench, and
`make regress` runs all of them (see [Running](#running)).

After the signature, `tb_matrix_mult_wrapper_full_bist` also reads the debug
pages: status (only `ext_en` set), the weight checksum, 64 input and 64 output
rows, and the event flags (the 8-bit flag follows the predicted dot products).
