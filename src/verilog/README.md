# Matrix Mult RTL (Milestone 1b + Tiling)

This directory has my RTL for a 4x4 weight-stationary systolic array matrix multiplication unit, plus the testbench used to verify it. Milestone 1b supported memory mode with one 4x4 weight tile. I have since added tiling across K and N, so memory mode now handles matrices up to 64x64 whose dimensions are multiples of 4. The testbench has been updated for tiling (see [Tiling tests](#tiling-tests)).

## File Organization

| File | Description |
|------|-------------|
| `matrix_mult/matrix_mult.sv` | Top level. Connects the controller and the systolic array to the memories, and holds the partial sum accumulate and saturate datapath |
| `submodules/controller.sv` | FSM that detects the start edge, loops over the K and N tiles, drives memory addresses and enables, and generates the array control signals |
| `submodules/controller_fsm_pkg.sv` | FSM state enum (`IDLE`, `LOAD_WEIGHT`, `STREAM`, `DRAIN`, `DONE`) |
| `submodules/systolic_array.sv` | 4x4 grid of PEs with the input skew buffers, output de-skew buffers, and the valid delay line |
| `submodules/PE.sv` | One processing element. Holds a weight and computes `south = weight * west + north` |
| `submodules/shift_buffer.sv` | Parameterized delay line. `BUFFER_LENGTH=0` is a plain wire |
| `submodules/saturate.sv` | Combinational clamp from `INPUT_WIDTH` to `OUTPUT_WIDTH` signed bits. `sat_o` is high when it clamps |
| `submodules/debug_obs.sv` | Debug observation add-on: counters, sticky event flags, and the page mux that drives `extra_output_bits_o` (see [Debug observation add-on](#debug-observation-add-on)) |
| `tb_matrix_mult.sv`, `verif/` | Testbench, assertion checkers, and coverage (see [verif/README.md](verif/README.md)) |
| `../../scripts/gen_golden.py` | Generates test vectors and golden outputs with my milestone 1a C simulator (`src/Simulator`) |

## Design

### Datapath

- **PE:** Each PE holds one signed 8-bit weight. In compute mode it passes its activation east and outputs `weight * west_i + north_i` to the south. Partial sums are 18 bits wide (`2*8 + log2(4)`), so nothing inside the array can overflow. During weight loading (`load_weight_i`), the PE passes `north_i` straight through to the south instead. On the last load cycle, `write_weight_i` latches `north_i` as the PE's weight.
- **Weight loading:** The weights enter from the top of the array on the same wires as the partial sums. The controller reads weight rows in reverse order (row 3 first). They shift down one PE row per cycle, so after 4 cycles PE row k sees row k of B, and `write_weight_i` captures all 16 weights at once.
- **Activation skew:** One activation row (one memory word) is read per cycle. Lane k of the word goes to array row k through a `shift_buffer` of length k, so lower rows are delayed to line up with the partial sums coming down the array. Activations are forced to 0 when they are not valid, so nothing stray gets accumulated.
- **Output de-skew:** Column j finishes j cycles after column 0, so its output goes through a `shift_buffer` of length `3 - j`. This lines up a full output row so it can be written to memory as one word. A 1-bit delay line of length `H + W - 1` produces `psum_valid` at the same time.
- **Accumulation and saturation:** Partial sums for each output row are accumulated in the output memory across the K tiles. In `matrix_mult`, the 18-bit array output goes through a 1-cycle register (`shift_buffer` of length 1) so it lines up with the old partial sum read from memory. Each lane then:
  1. Sign-extends both values to 19 bits and adds them. On the first K tile, the old value is 0 and memory is not read.
  2. Saturates the sum to signed 16 bits (partial sum) and to signed 8 bits (final output), using two `saturate` instances in parallel.
  3. Writes the 16-bit value back, or on the last K tile, the 8-bit value sign-extended to 16 bits.

  This matches my C simulator, which saturates to 16 bits on every accumulate and to 8 bits at the end (saturating to 8 bits directly gives the same result as saturating to 16 bits first).

### Controller

| State | What happens |
|-------|--------------|
| `IDLE` | Waits for a rising edge of `start_i` |
| `LOAD_WEIGHT` | Reads the 4 rows of the current weight tile in reverse order (4 cycles) |
| `STREAM` | Reads all `i_rows` rows of the current activation strip (1 per cycle) |
| `DRAIN` | Waits until the last output row of this tile has been written, then goes to `LOAD_WEIGHT` for the next tile or to `DONE` after the last one |
| `DONE` | Holds `done_o` high until the next `start_i` rising edge or reset |

- **Start detection:** `start_i` is registered and the FSM only starts on `start_i & ~start_previous_r`. During reset, `start_previous_r` tracks `start_i` instead of resetting to 0. This way, a `start_i` that is already high when reset is released is not mistaken for a rising edge.
- **Memory latency:** The memories have a 1-cycle read latency, so the array control signals (`load_weight`, `write_weight`, `act_valid`) are registered one cycle after the read is issued.
- **Tile loop:** Like my simulator, N is the outer loop and K is the inner loop, so each weight tile is loaded only once. `k_count_r` and `n_count_r` update once per tile on `tile_done_w`, which is high on the cycle `DRAIN` finishes. K wraps to 0 and N increments when `last_k_w` is high. `last_k_w` and `last_n_w` compare the counters to the last tile index (`w_rows/Tk - 1` and `w_cols/Tn - 1`). I store the last index instead of the tile count so it fits in the counter width at 64.
- **No M tile loop:** The weights stay in the array for every M tile, and each activation row only produces its own output row. So `STREAM` sends all `i_rows` rows back to back instead of draining after every 4 rows. This takes fewer cycles and gives the same results. I updated my simulator's `systolic_run_gemm` to stream the same way.
- **Tile offsets:** Instead of multiplying tile indices, the controller keeps one offset register per memory and adds a constant when a tile finishes:

  | Offset | On every tile | On the last K tile |
  |--------|---------------|--------------------|
  | `w_tile_offset_r` | `+ Tk` | `+ Tk` |
  | `i_tile_offset_r` | `+ i_rows` | reset to 0 |
  | `p_tile_offset_r` | no change | `+ i_rows` |

  Each address is `config offset + tile offset + rd_count_r` (or `wr_count_r`). The offsets count words, and each word is one tile row.
- **Partial sum read and write:** When `psum_valid` is high, the controller reads the old partial sum at `psum_offset + p_tile_offset_r + wr_count_r` through the `*_R_*` port. It skips the read on the first K tile. The write through the `*_W_*` port happens one cycle later, using a registered copy of `psum_valid` and of the address. `DRAIN` ends when `wr_count_r == i_rows`, which is the cycle of the last delayed write. That way the tile counters, `first_k_o`, and `last_k_o` don't change until the last row is written, and `done_o` only goes high after it is in memory.

### Debug observation add-on

This is our add-on (approved by the TA). It puts internal state on the 8 output scan bits so the testers can see what the chip is doing, even with the clock stopped. The 4 input scan bits pick what is shown:

| Bits | Use |
|------|-----|
| `extra_config_i[0]` | `fp_en`, reserved for the FP8 stretch goal. It has no effect yet and is only echoed on the status page |
| `extra_config_i[3:1]` | `obs_sel`, the page shown on `extra_config_o[7:0]` |

| `obs_sel` | Page | Bits |
|-----------|------|------|
| 0 | Status | [2:0] controller state, [3] `done_o`, [4] `ext_en_i`, [5] `fp_en`, [6] start edge seen, [7] 0 |
| 1 | Tile progress | [7:4] N tile, [3:0] K tile |
| 2 | Read counter | [6:0] `rd_count_r`, [7] in `STREAM` |
| 3 | Write counter | [6:0] `wr_count_r`, [7] `last_k` |
| 4 | Weight checksum | XOR of all 16 PE weights |
| 5 | Output rows | Cycles the array's `psum_valid` was high (8 bits, wraps) |
| 6 | Input rows | Cycles the array's `act_valid` was high (8 bits, wraps) |
| 7 | Event flags (sticky) | [0] partial sum saturated to 16 bits, [1] output saturated to 8 bits, [4:2] 0 (reserved for FP flags), [5] weight load seen, [6] input valid seen, [7] output valid seen |

- `debug_obs.sv` holds the counters, flags, and page mux. `matrix_mult_9` only wires signals into it. The controller exposes its state, counters, and start pulse. Each PE exposes its weight, and `systolic_array` XORs them into `weight_xor_o`.
- The page mux is combinational with no register after it, so the testers can stop the clock (`en_i`) and still switch pages. The weight checksum is the only combinational source, and the PE weights only change on `write_weight`.
- Counters and flags clear on reset and on a start edge. "Start edge seen" only clears on reset.
- The saturation flags only set when the value is actually used: the 16-bit flag on a delayed partial sum write that is not the last K tile, and the 8-bit flag on the last K tile's write or a valid external result. Between those cycles the saturators see stale data.
- `debug_obs` uses `rstn_i`, not the memory controller's reset, so pages 4 to 7 still work in external and BiST mode. Pages 0 to 3 show `IDLE` and zero counts there because the controller is held in reset.
- The row counters wrap at 256 (a 64x64x64 run produces 16384 rows), so compare them mod 256. The tile fields are size-cast to 4 bits so other array sizes still fit.
- With `extra_config_i` all 0 the design behaves the same as before, and all the existing tests run that way.

## Memory Layout

All three memories store **one tile row (4 elements) per word**, with the **lowest column in the least significant bits**. Each matrix is split into 4-wide column strips, and each strip is stored as a contiguous block of words. This way every tile is read with sequential addresses. In the table, `t` is the K tile index for A and the N tile index for B and C, and `j` is the element's position in the word (0 to 3).

| Memory | Word width | Word address | Element in word |
|--------|-----------|--------------|-----------------|
| Activation (A, M x K) | 32 bits (4 x 8) | `i_offset + t*M + r` holds row r of strip t | A[r][4t+j] at bits `[8j+7 : 8j]` |
| Weight (B, K x N) | 32 bits (4 x 8) | `w_offset + t*K + k` holds row k of strip t | B[k][4t+j] at bits `[8j+7 : 8j]` |
| Output (C, M x N) | 64 bits (4 x 16) | `psum_offset + t*M + r` holds row r of strip t | C[r][4t+j] at bits `[16j+15 : 16j]` |

Weight tile (k, n) is the 4 words starting at `w_offset + n*K + 4k`. During a run, the output memory holds 16-bit saturated partial sums. After the last K tile, each lane holds the final 8-bit result sign-extended to 16 bits. With K = N = 4, this is the same layout as milestone 1b and the example files in `doc/examples/milestone_1b`.

### Example: 4x4 Identity Matrix

The identity matrix

```
01 00 00 00
00 01 00 00
00 00 01 00
00 00 00 01
```

is loaded into **both** the activation memory and the weight memory (with `i_offset = w_offset = 0`) as:

```
[MSB:LSB]
addr 0: 0x00000001
addr 1: 0x00000100
addr 2: 0x00010000
addr 3: 0x01000000
```

The DUT reads these words directly with no transposing or staggering in memory. Weights are read from addr 3 down to addr 0 during `LOAD_WEIGHT`, and activations from addr 0 up to addr 3 during `STREAM`. Since I x I = I, the DUT writes the following to the output memory (with `psum_offset = 0`). Each element is in a 16-bit lane:

```
[MSB:LSB]
addr 0: 0x0000_0000_0000_0001
addr 1: 0x0000_0000_0001_0000
addr 2: 0x0000_0001_0000_0000
addr 3: 0x0001_0000_0000_0000
```

A negative result such as -1 (`0xFF`) is written as `0xFFFF` in its lane. The low byte of each lane is the 8-bit result. `OUTPUT_MEM.hex` in the examples and the generated tests holds the full 16-bit lanes.

## Running the Testbench

Besides `src/verilog`, my submission tarball includes the files the test framework needs from the rest of the repo: `scripts/gen_golden.py`, my C simulator in `src/Simulator`, `doc/examples`, and the `sim/behav` Makefile (a symlink to `src/Makefiles/Makefile_sim_presyn`). Extract it at the repository root so the relative paths line up.

From `sim/behav` on the ECE server:

```
make                           # same as make vcs: build the C simulator, generate golden data, compile and run with coverage
make vcs TEST=rand_full_0      # run a single test from tests.list
make cov_report                # coverage report in urgReport/dashboard.html
make golden NUM_RANDOM=50 SEED=7   # only regenerate the test vectors
make regress                   # memory, external and wrapper/BiST testbenches, then a PASS/FAIL summary
make help                      # list all targets
```

`make verify` still works as another name for `make vcs`.

`make golden` runs `scripts/gen_golden.py`. The script builds the C simulator in `src/Simulator`, runs it to get the golden output, cross-checks it against a separate Python model, and writes `ACT_MEM.hex`, `WEIGHT_MEM.hex`, `OUTPUT_MEM.hex`, and `golden.log` for each test. The testbench loads the hex files with `$readmemh`, pulses `start_i`, waits for `done_o`, and compares the output memory against the golden data. The run ends with `TB RESULT: PASSED` or `TB RESULT: FAILED`.

There are 147 generated tests (identity, routing, saturation boundaries, operand corner values, random, longer activation streams, and tiling) plus directed tests for start/done handshaking, nonzero offsets, and reset in every FSM state. Each module also has a bound assertion checker with coverage. The test list and checkers are described in [verif/README.md](verif/README.md).

### Tiling tests

`gen_golden.py` now writes the tiled memory layout. For K = N = 4 the files are the same as before, so the 113 milestone 1b tests are unchanged. I added 34 tiled tests: N loop only, K accumulation only, both, non-square shapes, 64x64x64, routing across strips, and 16-bit partial sum saturation between K tiles. The testbench reads M, N, and K from `tests.list`, and its SV reference model accumulates across K tiles with 16-bit saturation. The directed tests now also cover restarting from DONE with a different shape, offsets with several strips, and a reset sweep on a 4-tile run. I updated the checkers for the tiled addresses, the partial sum read, and the delayed write.

The full run (169 runs) passed with 0 assertion failures under Verilator 5.052. I still need to run it with VCS on the ECE server. Verilator could not compile the `cp_trans` transition coverpoint in `controller_checker.sv`, so that coverpoint was removed for the Verilator run only.

### Debug add-on tests

`verif/debug_obs_checker.sv` has its own model of every page and checks `obs_o` in every cycle of every testbench. The `saturate` and `systolic_array` checkers also check `sat_o` and the weight checksum. The new directed test `debug_obs_pages` steps through every page during a run that saturates, then reads the pages in DONE and compares them with values computed from the test. The full BiST testbench also reads the pages after the signature. See [verif/README.md](verif/README.md).

## AI Usage Disclosure

I used **Claude Code** (Anthropic), an agentic coding assistant running in VS Code, for this milestone. It could read files in the repository, run shell commands, and create or edit files. All milestone 1b sessions used **Claude Opus 5.5** and took place between Oct 14 and Oct 18, 2026 (10 sessions, including the one that wrote this README). My AI usage for milestone 1a is disclosed in [src/Simulator/README.md](../Simulator/README.md). I have saved the full chat logs and can provide them on request. The git history shows the code at each step: commit `0d642b8` is my RTL, and `84fb8ce` adds my bug fixes and the AI-generated testbench. My AI use for the tiling work after milestone 1b is disclosed separately in [Tiling (Oct 26, 2026)](#tiling-oct-26-2026).

For the RTL, I usually told Claude not to modify files. It reviewed my code and explained problems, and I made the changes myself. The verification files were generated by Claude.

### What AI generated or influenced

The percentages are approximate. They count the non-boilerplate lines in each file (excluding TA-provided lines) that are identical to a line in code Claude showed me in chat.

| File | AI involvement |
|------|----------------|
| `PE.sv` | **Written by me** (~8% matches AI code). Claude reviewed it, found a missing semicolon, and pointed out that the signals needed to be `signed` for 2's complement inputs. It also explained the timing of latching the weight from `north_i`. |
| `shift_buffer.sv` | **Written by me** (~25%). Claude found that `stored_data` was declared as an unpacked array, which would not compile. It also showed me how to use a `generate if` for the `BUFFER_LENGTH=0` pass-through case, which I then added. |
| `saturate.sv` | **Written by me** (~8%). Claude found a trailing comma in the parameter list and explained signed comparison and constant sizing for the `MAX`/`MIN` localparams. |
| `systolic_array.sv` | **Mostly written by me** (~20%). Claude reviewed it and found several bugs: an undriven row 0 input buffer, off-by-one de-skew buffer lengths, a 1-bit `localparam` that truncated the accumulator width, and width mismatches. I fixed these myself. |
| `controller.sv` | **Based on an AI skeleton** (~60%). I wrote a first version, which had the wrong port list and a counter in an `always_comb`. I asked Claude what the controller's inputs and outputs should be and where the control signals should be generated. Claude showed a full controller skeleton in chat, which I used as the starting point. I adapted it and added the comments. The `start_previous_r` reset fix was also suggested by Claude. |
| `matrix_mult.sv` (non-TA lines) | **Based on AI suggestions** (~75%). Claude showed how to wire the controller, array, and saturators together and which parts belong at the top level versus in the controller. I wrote the final file from that. |
| `verif/*` (all checkers, binds, tasks, `README.md`), `tb_matrix_mult.include` | **Generated by Claude** (~100%) at my request. |
| `tb_matrix_mult.sv` | TA-provided. Claude modified it to run the test list and include the checkers. |
| `scripts/gen_golden.py` | **Generated by Claude** (~100%). It uses my milestone 1a C simulator as the golden model. |
| `Makefile_sim_presyn` | Claude added the `golden`, `cov_report`, and other targets, and changed `vcs` to compile `tb_matrix_mult.include` and run the full flow. |
| This `README.md` | Drafted by Claude from my code and my saved chat logs at my request. I reviewed and edited it. |

### How I used AI (sessions and example prompts)

1. **Bug checking each module (Oct 14-15).** I opened each submodule and asked Claude to review it without editing:
   - `PE.sv`: *"Is this file likely to function correctly? Are there any major bugs? Can you help me understand the timing implications of saving the north input to weight on the clock edge versus saving east_next_r to the weight on the clock edge?"*
   - `shift_buffer.sv`: *"Is this the correct way to implement a shift buffer? Are there any major errors in this code?"* and *"What do you mean by using generate to enable creation of a 0 length buffer? Can you show me what this code would look like (do not edit the file)"*
   - `saturate.sv`: *"Is this a valid implementation of a saturation function? Is there any bug in the parameter calculation? ... Should I remove the clk_i and rstn_i if it is not clocked?"*, with follow-ups on `<<<` vs `<<` and why `MAX`/`MIN` were sized to `INPUT_WIDTH`.
2. **Combining the modules (Oct 18).** *"Can you help me identify any major bugs with this systolic array implementation and finish up the FSM to fix timing issues. I am having a hard time think of how to ensure that zeros are shifted into the input buffers at the appropriate time during fill, how to set the proper row's bit for the write_weight_r during weight loading ... Don't modify any code, just give clarifications on what needs to be fixed."* Follow-ups: *"Can you help give me more specifics about what code to move into matrix_mult.sv, and how to fix the timing and control signal organization?"*, *"Can you help me with controller.sv and integrating the packages into matrix_mult.sv? What inputs and outputs should the controller have?"*, and *"What needs to be changed to prep for beyond milestone 1b? Like how would I have a 16 bit and 8 bit saturator?"* This is where the controller skeleton and the top-level wiring came from.
3. **Understanding the spec and memories.** *"The doc/Milestone_1b.md references $readmem[b/h] but I can't find this function anywhere..."*, *"Can you explain the memory signals used in this design? What does cenb, wenb mean?"*, and *"Is it okay that stream reads a row? Does it need to read a column instead?"*
4. **Testbench (Oct 18).** *"Can you help me create a testbench setup for the matrix_mult_pkg.sv to complete the requirements for doc/Milestone_1b.md while keeping in mind the larger project described in README.md. Use the src/Simulator that I developed to create golden logs. Create coverage groups and assertions to validate individual modules and the overall functionality."* Claude generated everything in `verif/` and `gen_golden.py`. It ran the testbench with Verilator on a scratch copy of my RTL (VCS was not available locally). It reported the compile errors it found but did not edit my RTL, so I fixed them myself. It also found that the design started if `start_i` was held high through reset. I then asked *"Is it possible to fix the start capture issue. start_previous_r needs to have some default value so it can act up on reset"*, and applied the suggested fix.
5. **Documentation.** I asked Claude to read my previous chat sessions so I could summarize my AI usage, and to write this README from the TA's README requirements (memory layout example and AI citation policy).

### Files the AI read

To answer questions and generate code, Claude Code read the top-level `README.md`, `doc/Milestone_1b.md`, `doc/tiled_gemm_ex.pdf`, `doc/wrapper_memory_ex.png`, `doc/examples/`, `img/tb_setup.png`, every file in `src/verilog/` (including the TA-provided package, wrapper, memory emulators, and testbench), `src/Makefiles/`, `sim/behav/Makefile`, and `src/Simulator/`. It also read the git history and my saved Claude Code chat logs (for this disclosure).

### Tiling (Oct 26, 2026)

I added tiling in one Claude Code session (Claude Opus 5.5) on Oct 26, 2026, which also wrote this section. I told Claude I wanted to write the RTL myself. It explained the design and reviewed each version of my code, but did not edit any RTL. It did not show me any RTL. It only gave explanations, tables, and one pseudocode/block diagram of the accumulate datapath. These changes are in commit `7d1c4a4`.

| File | AI involvement |
|------|----------------|
| `controller.sv` (tiling changes) | **Written by me from AI design guidance** (~0% of the new lines match AI code). Claude suggested the tiled memory layout, streaming all M rows in one pass instead of an M tile loop, the "odometer" counter pattern (`tile_done_w` with `last_k_w`/`last_n_w`), the offset registers and how much each one adds, the delayed write, and moving the `DRAIN` exit to `wr_count_r == i_rows`. Most of the new signal names came from its suggestions, as did the `_r`/`_w` renames to match the TA wrapper. Its reviews found bugs that I fixed: latches from next-count values assigned in `always_comb`, a tile count that overflowed its width at 64, counters that updated a cycle late, a `<` instead of `<=`, offsets that added `Tm` instead of `i_rows` (and one that was missing the add), a read enable with the wrong logic (De Morgan), an inverted reset on the delay registers, and missing `assign` keywords. |
| `matrix_mult.sv` (tiling changes) | **Written by me from AI design guidance** (~0%). Claude explained which accumulation logic belongs here versus in the controller, the 1-cycle pipeline register, the 19-bit sign-extended add, and the two saturators with the `last_k` mux. It also said to pass `Tn` to the controller. Its reviews found: `generate` used inside `always_comb`, missing semicolons, the wrong sign bit, cutting the array output down to 16 bits, indexing `ob_mem_data_R_i` by bits instead of by lane, unsigned (zero-extended) addition, a 16-bit saturator that was 18 bits wide, a whole-array assignment inside the per-lane loop, an undriven `ob_mem_data_R_o`, replication syntax, and the output mux assigned to `ob_mem_addr_W_o` instead of `ob_mem_data_W_o`. It also recommended `assign` with `?:` instead of one `always_comb` per lane. |
| This `README.md` (tiling sections) | Drafted by Claude from my code and this session at my request. I reviewed and edited it. |
| `scripts/gen_golden.py`, `verif/tb_matrix_mult_tasks.sv`, `verif/controller_checker.sv`, `verif/matrix_mult_checker.sv`, `verif/mm_binds.sv`, `verif/README.md` (tiling updates) | **Generated by Claude** (~100%) in a second session on Oct 26, 2026, at my request. Claude ran the tests with Verilator on a scratch copy and did not edit my RTL. |
| `src/Simulator/systolic.c`, `systolic.h` (M streaming change) | **Edited by Claude** at my request in that same session, so the simulator streams all M rows per weight tile like my RTL. See [src/Simulator/README.md](../Simulator/README.md). |

Example prompts:

1. **Planning.** *"Can you help guide me in implementing tiling in my RTL code to match this simulator behavior? I want to write the RTL on my own, I am just unsure where to start and what needs to change."* Follow-ups: *"Doesn't there need to be a loop for m_tiles that repeats stream and drain m_tiles times?"* and *"Is there any scenario where this would not work? Are there any disadvantages to it? Will it work with the debug mode..."*
2. **Controller.** *"I did implement counters for n and k. The implementation of these counters feels a bit awkward. Did I implement them correctly? Is there a more elegant or better practice way to implement them?"*, *"Shouldn't w_base increase by Tn since this is the width of the weight array?"*, *"Will each memory address always hold one whole row?"*, *"Is the controller.sv implementation for tiling now correct? Are there any code formatting suggestions you have? Did I use _r in the correct locations?"*, and *"How do I adjust this to delay the memory write signals by a cycle? Is the read implementation correct?"*
3. **Accumulation datapath.** *"Can you help me understand how to implement the accumulation changes? Are those just changes in matrix_mult.sv?"*, *"I am confused what the implementation in matrix_mult.sv should look like"*, *"Did I implement matrix_mult.sv correctly? It feels like maybe I used the generates wrong inside the always_comb"*, and *"Does this fix those issues?"* (twice).
4. **Documentation.** *"Can you update the README with this implementation and the AI usage to implement it?"*
5. **Tiling tests (second session).** *"Can you update the tests to add testing for tiling and make sure old tests are still compatible with tiling. Update the README minimally but accordingly to ensure this AI usage and the testing added is updated"*, then *"Did you adjust the simulator c file to reflect the lower amount of cycles needed because staggering is not done independently for each M tile?"* and *"Can you update the simulator just to correct this cycle count issue?"*

Files Claude read in this session: my C simulator (`systolic.c`, `systolic.h`, `config.h`, `mem.c`), the top-level `README.md`, `doc/Milestone_1b.md`, `doc/examples/milestone_1b/`, `scripts/gen_golden.py`, `controller.sv`, `controller_fsm_pkg.sv`, `matrix_mult.sv`, `matrix_mult_pkg.sv`, `systolic_array.sv`, `shift_buffer.sv`, `PE.sv`, `saturate.sv`, `memory/mem2p_emulator.sv`, parts of `matrix_mult_wrapper.sv` and `tb_matrix_mult.sv`, searches of `tasks.sv`, `bist/`, `misc/` and `verif/`, my notes on the planned debug mode, this README, and the git status, diffs, and log. In the tiling tests session, Claude read `controller.sv`, `matrix_mult.sv`, `controller_fsm_pkg.sv`, `matrix_mult_pkg.sv`, `tb_matrix_mult.sv`, `tasks.sv`, `tb_matrix_mult.include`, every file in `verif/`, `scripts/gen_golden.py`, `src/Makefiles/Makefile_sim_presyn`, `src/Simulator/` (`systolic.c/.h`, `config.h`, `main.c`, `run.sh`, `README.md`, `test_sim.py`), this README, and my saved memory notes.

### Branch merge and regression target (Oct 28, 2026)

I used one Claude Code session (Claude Opus 5.5) to plan merging our team branches into `main` and to check our milestone 1c coverage. I did the merge and branch cleanup myself. Claude did not edit any RTL. It compiled the external and wrapper testbenches with Verilator on a scratch copy to check that they pass.

| File | AI involvement |
|------|----------------|
| `src/Makefiles/Makefile_sim_presyn` (`wrapper` and `regress` targets) | **Generated by Claude** (~100% of the new lines) at my request. I ran it on the ECE server. |
| `tb_matrix_mult_wrapper.include` | **Generated by Claude** (~100%). |
| `verif/README.md` (Running section, wrapper run paragraph) | **Edited by Claude** at my request. |
| This subsection | Drafted by Claude. I reviewed it. |

Example prompts: *"Can you make sure everything for the assignment is implemented (besides the add-on)? And that running make from sim/behav runs all the required tests"*, *"Can you write that so I can run the full tests on the server"*, and *"Yes, please update the README (also add minimal ai usage disclosure for this conversation if needed)"*.

Files Claude read in this session: the top-level `README.md`, `doc/Milestone_1b.md`, `src/Makefiles/Makefile_sim_presyn`, every `.include` file, `matrix_mult.sv`, `matrix_mult_wrapper.sv`, `misr.sv`, the external and wrapper testbenches, `verif/README.md`, `verif/tb_matrix_mult_tasks.sv`, the `controller`, `misr`, `lfsr` and `matrix_mult` checkers, `mm_binds.sv`, `wrapper_binds.sv`, `mm_verif_defs.svh`, `scripts/gen_golden.py`, this README, my saved memory notes, and the git log, branches and diffs.

### Debug add-on (Oct 22-30, 2026)

I planned the add-on with Claude Code (Claude Opus 5.5) in one session from Oct 22 to Oct 26. We compared FP8 options and picked the debug observation mux, with FP8 as a stretch goal. Claude wrote the scan bit and page plan into a notes file. I implemented it in a second session from Oct 28 to Oct 30. I told Claude I wanted to write the RTL myself. It made the plan of which files to change, then reviewed each version of my code. Apart from the 5 lines below, it did not edit my RTL.

| File | AI involvement |
|------|----------------|
| `debug_obs.sv` | **Written by me from AI design guidance** (~5% matches AI code). Claude described what the module should contain (ports, counters, flags, page mux), said to keep the mux inside it instead of in `matrix_mult_9`, which signals gate each flag, and that "start seen" needs its own block. Its reviews found: decimal case labels (`010` is ten, so pages 2 to 7 never matched), missing semicolons, blocking `=` in `always_ff`, 9-bit counters, the wrong bit order on page 7, and a missing external saturation term. At my request, Claude wrote the page 1 lines (the 4-bit size casts and their comment). |
| `systolic_array.sv` (weight checksum) | **Written by me** (~20%). My first version had 16 `assign`s to one net (multiple drivers and a combinational loop). Claude explained why and described the `always_comb` loop I used. It also found undeclared loop variables. |
| `PE.sv`, `saturate.sv`, `controller.sv` (debug ports) | **Written by me** (~0%). Claude listed the ports to add. It pointed out that renaming `weight` to `weight_r` broke the `.*` bind of `PE_checker`, which I fixed. |
| `matrix_mult_9.sv` (debug wiring) | **Written by me** (~0%). Claude recommended a separate OR reduction per saturator group instead of one combined flag. Its reviews found: commas instead of semicolons, missing `assign`s, an OR of the wrong signal, parameter declaration syntax in the instance, a capitalized signal name, a second driver on `extra_output_bits_o`, and the controller-only `load_weight`/`act_valid`. |
| `verif/debug_obs_checker.sv`, `verif/mm_binds.sv`, the `saturate` and `systolic_array` checkers (debug checks), `verif/tb_matrix_mult_tasks.sv` (`debug_obs_pages`), `tb_matrix_mult_wrapper_full_bist.sv` (debug page checks), the checker line in each `.include`, `verif/README.md` | **Generated by Claude** (~100% of the new lines) at my request. Claude ran all six testbenches with Verilator on a scratch copy. The memory, external, and wrapper external/registered testbenches pass. The two BiST testbenches pass every check except a reset-time LFSR/MISR seed assertion that also fails on the committed code under Verilator (VCS passes it). Claude also added bugs to the scratch copy to check that the new tests catch them. |
| This README (debug sections) | Drafted by Claude at my request. I reviewed it. |

Example prompts: *"Can you help me create a plan to implement the add-ons as discussed with a previous claude code section and saved here? What files do I need to edit? What changes do I need to make?"*, *"Is this the correct way to xor the internal weights? Does weight_xor_o need an initial signal? Should this be flopped for debug purposes?"*, *"Is this or reduction of sat_o the best way to do this?"*, *"I am confused what debug_obs is supposed to contain. And should the extra_output_bits just be muxed in matrix_mult or maybe be a submodule"*, *"Have I implemented everything correctly now?"*, *"when does the Tk=Tn=4 not the case? Can you fix this implementation for me?"*, and *"Can you update the README to reflect this implementation and the AI use for it. Can you also add assertions and testing for this added functionality"*. In the planning session: *"Shouldn't those scan bits be used for debugging visibility for the entire design, not just the FP"*.

Files Claude read in the implementation session: my saved notes on the debug mode, `matrix_mult_9.sv`, `matrix_mult_pkg.sv`, `matrix_mult_wrapper_9.sv`, `controller.sv`, `controller_fsm_pkg.sv`, `PE.sv`, `saturate.sv`, `systolic_array.sv`, `debug_obs.sv`, `bist/pseudo_rand_num_gen_9.sv` and `lfsr_9.sv`, every `.include` file, all the `verif/` checkers it changed plus `controller_checker.sv`, `mm_verif_defs.svh`, `mm_verif_pkg.sv`, `tb_matrix_mult.sv`, `verif/tb_matrix_mult_tasks.sv`, `tb_matrix_mult_wrapper_full_bist.sv`, `sim/behav/Makefile`, `src/syn/read.tcl`, `constraints.tcl`, `scripts/gen_golden.py`, both READMEs, my saved memory notes, the planning session's log (for the prompts above), and the git status and diffs.
