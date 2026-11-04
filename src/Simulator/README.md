# Weight Stationary Tiled Systolic Array Simulator

I built a cycle-level simulator of the project's weight-stationary systolic array in C. The simulator does tiled matrix multiplication (GEMM) on an `R x C` grid of processing elements and computes `C = A x B` where A is an activation matrix of dimensions `M x K`, B is the weight matrix of dimensions `K x N`, and C is the result matrix of dimensions `M x N`. The default operating mode saturates to 16-bit partial sums and 8-bit outputs but these are parameterizable. A Python implementation of matrix multiplication using NUMPY is also included to verify this simulator. The simulator operates at a bit-level, simulating the individual PEs and accounting for reading from memory.

## Requirements

- A prebuilt `sim.out` for the ECE Linux servers is included, so nothing is needed just to run the simulator.
- To rebuild from source: a C11 compiler (`cc`/`gcc`) and `make`.
- Python 3 and numpy (listed in `requirements.txt`), **only** to run the test script (`test_sim.py`). The simulator itself has no Python dependency.

## Building

The included `sim.out` was built on the ECE server. To rebuild it:

```
make clean
make
```

This compiles the five `.c` files into `sim.out`. The Makefile links statically (`-static`) when the system has the static C library. The ECE servers do not have it, so there `sim.out` is linked against the system C library (glibc) only. The simulator uses no other libraries. All files needed to build are included in this folder.

To install the test dependencies:

```
pip install -r requirements.txt
```

## Running the Simulator

```
./run.sh <Num Array Rows> <Num Array Cols> <M> <N> <K> <Path to A> <Path to B> <Path to write C>
```

Example:

```
./run.sh 4 4 8 8 8 A_matrix_8.txt B_matrix_8.txt C_out.txt
```

`run.sh` runs the included `sim.out` (it only builds it with `make` if the binary is missing) with the given arguments. The simulator rejects the run with a usage message and a nonzero exit code if:
- `M` or `K` is not a multiple of the number of array rows
- `N` is not a multiple of the number of array columns
- any dimension is not a positive integer

## File Format

A, B and C use the same text format as the files in `doc/examples`:
- one matrix row per line
- elements separated by spaces
- each element is a 2-digit, two's complement hex value (for example `FE` = -2 and `7F` = 127)

A is read as `M x K`, B as `K x N`, and C is written as `M x N`.

## Code Organization

| File | Purpose |
|------|---------|
| `run.sh` | Runs `sim.out` with the 8 arguments (builds it first if it is missing). |
| `sim.out` | Prebuilt simulator binary for the ECE Linux servers. |
| `main.c` | Parses arguments, loads A and B, runs the tiled GEMM, and writes the C output matrix. |
| `config.c/.h` | Parses and checks the command line arguments into `sim_config_t`. Defines the bit widths `OUT_WIDTH_BITS` (8) and `PSUM_WIDTH_BITS` (16). |
| `mem.c/.h` | Matrix and partial sum memory structures, reading and writing matrix files, sign extension, and saturation helpers. |
| `PE.c/.h` | Model of one PE. Holds a stationary weight and does one multiply-accumulate (MAC) per cycle. |
| `systolic.c/.h` | A grid of PEs. Performs weight tile loading, single-cycle stepping, streaming one tile with input skew, and the top-level tiling controller. |
| `Makefile` | Builds `sim.out` from the C sources (statically linked when possible). |
| `requirements.txt` | Python packages needed by `test_sim.py`. |
| `test_sim.py` | **For testing the simulator functionality only.** Checks the simulator's output against a numpy reference model (see [Testing](#testing)). It is not part of the simulator. |

## Key Data Structures

- **`pe_t`** (PE.h): one PE. Holds its stationary `weight` and two output registers, `act_out` (passed east) and `psum_out` (passed south). Each cycle it computes `psum_out = psum_in + weight * act_in`. Values are `int64_t`, so the array keeps full precision.
- **`systolic_array_t`** (systolic.h): a 2D grid of `pe_t` plus a cycle counter.
- **`matrix_t`** (mem.h): a row-major matrix used for A, B and C.
- **`psum_mem_t`** (mem.h): the `M x N` partial sum memory. Every add into it saturates to signed 16 bits.
- **`sim_config_t`** (config.h): the array size, M/N/K, and the file paths from the command line.

## How It Works

1. **Load weights:** a 4x4 (R x C) tile of B is loaded into the PEs. It stays there while activations stream through.
2. **Stream activations:** a tile of A enters from the west edge. Row `i` is delayed by `i` cycles so the data lines up diagonally. This skew is done while streaming, not stored in memory. Partial sums flow down each column and come out the bottom.
3. **Accumulate:** each output tile is added into partial sum memory (saturating to 16 bits).
4. **Tiling:** the loop order is N tiles, then K tiles. Each weight tile is loaded only once, and all M activation rows of that K strip stream through back to back while it is loaded. This matches my RTL, so the array fills and drains once per weight tile instead of once per M tile.
5. **Output:** after all K tiles are added, each value is saturated to signed 8 bits and written to C.

`systolic_step` updates the PEs from the bottom-right corner to the top-left. Each PE then reads its neighbors' values from the previous cycle, like registers on a clock edge.

## Testing

`test_sim.py` is only used to test the C simulator. It is not part of the simulator. It generates random and edge-case matrices, runs `run.sh`, and checks C against a numpy reference that does the same 16-bit partial sum and 8-bit output saturation.

```
python3 test_sim.py          # full test suite
python3 test_sim.py --quick  # shorter run
```

## AI Usage Disclosure

I used **Claude Code** (Anthropic), an agentic coding assistant running in VS Code, throughout this milestone. It could read files in the repository, run shell commands, and create or edit files. I used Claude Sonnet 5 / 5.5 for the early scaffolding and quick questions and Claude Opus 5.5 for the dataflow, memory, testing, and submission work. All work happened in 11 sessions between Oct 9 and Oct 11, 2026. I have saved the full chat logs and can provide them on request. The git history shows the state of the code at each commit.

### What AI generated

The percentages are approximate. They count the lines in the submitted file that are identical to a line Claude wrote, taken from the chat logs.

| File | AI involvement |
|------|----------------|
| `config.c/.h` | Generated by Claude (~90-100% of lines). I reviewed it and made small changes. |
| `mem.c/.h` | Generated by Claude (~75-93%). This includes `sign_extend`, `saturate`, matrix file I/O, and `psum_mem_accumulate`. I asked for the saturate function and where it should go. Claude also replaced `malloc` with `calloc` across the files at my request. |
| `PE.c/.h` | Generated by Claude (~85-90%) from the PE struct design I described. |
| `main.c`, `run.sh` | Generated by Claude (~75%). I modified them afterward. |
| `systolic.h` | Generated by Claude as a skeleton (~70%). I edited the function interfaces. |
| `systolic.c` | **Mostly written by me** (~30% matches AI-written lines). Claude generated the initial skeleton, `systolic_destroy`, and `systolic_reset`. I wrote `systolic_create`, `systolic_load_weight_tile`, `systolic_step`, `systolic_run_tile`, and `systolic_run_gemm`. While writing `systolic_run_tile` and `systolic_run_gemm`, Claude showed me example code in chat (at my request, without editing the file), reviewed my versions, and explained the tile offsets. |
| `Makefile` | Generated by Claude (~90%), including the tarball target. Claude also helped debug build and `tar` errors on the ECE server. |
| `test_sim.py` | Generated by Claude (~99%) after I asked for a numpy-based reference check. |
| `README.md` | Claude drafted the skeleton and the first full version. I asked for it to be cut down so it sounded like me, and I edited it afterward. This AI disclosure section was also drafted by Claude from my saved chat logs. |

### How I used AI (sessions and example prompts)

1. **Scaffolding.** *"Can you help create a skeletal structure of the bit level simulator of the systolic array discussed in the README? ... I thought the structure should be a PE struct or class instantiated by the systolic and connected together..."* This produced the initial versions of every `.c`/`.h` file and `run.sh`. Follow-ups: *"Can you implement config.c for me?"* and *"Can you help me create a makefile that builds this Simulator?"*
2. **Understanding the hardware interface.** *"Can you help me understand the input and output as described in matrix_mult_wrapper.sv and matrix_mult_pkg.sv? I want to make sure my simulator is simulating all of these input and output bits."* After discussing it, I decided to model the weight shift-in and memory access locations, and Claude rewrote the skeleton files to match.
3. **Design questions.** These included whether input and psum bit widths should be parameterizable, which direction the weights load from, and whether staggered input and output should share a struct.
4. **Dataflow and debugging (mostly explanation, no file edits).** Examples: *"I'm having a hard time wrapping my head around the number of cycles that need to be delayed on input and output... (don't change any actual files)"*, *"What should systolic_run_tile look like? Show me the code, don't edit the systolic.c document"*, and *"Does this implement a weight-stationary systolic array correctly according to the README...? Do not modify any files."* I corrected Claude twice. First, partial sums enter through the north edge rather than accumulating in memory inside the tile. Second, activations enter by row, with lower rows staggered.
5. **Memory and tiling.** *"Can you help me identify how to setup the offsets in systolic_run_tile correctly and what code is needed in systolic_run_gemm so that I am using gemm as specified in the doc/tiled_gemm_ex.pdf"* and *"mem.h and mem.c will also need a saturate function. Can you implement mem.c..."*
6. **C language questions.** These covered `inline`, `malloc` vs `calloc`, and how `sign_extend` works.
7. **Testing and submission.** *"For the milestone 1a submission, what more do I have to do to complete my simulator? Can you help me setup the testing...? I might want to use python's numpy..."*, followed by writing the README, packaging the tarball, and fixing `make`/`tar` errors on `ece-labsrv`.

### Files the AI read

Claude Code read these files to answer questions and generate code: the top-level `README.md`, `doc/Milestone_1b.md`, `doc/tiled_gemm_ex.pdf`, `doc/wrapper_memory_ex.png`, `doc/examples/*`, the images in `img/`, `src/verilog/matrix_mult/*.sv`, the files in `src/Makefiles/`, and every file in `src/Simulator/`. It also listed the repository's directory structure.

### Update after milestone 1a (Oct 26, 2026)

While I was adding tiling to my RTL (see [src/verilog/README.md](../verilog/README.md)), I asked Claude (Opus 5.5) to *"update the simulator just to correct this cycle count issue"*. Claude edited `systolic_run_gemm` in `systolic.c` (and the comment in `systolic.h` and the Tiling bullet above), so all M rows of a K strip now stream through in one `systolic_run_tile` call instead of one call per M tile, the same as my RTL. The outputs did not change: all 159 `test_sim.py` cases pass, and every golden file in the RTL test set is the same as before.
