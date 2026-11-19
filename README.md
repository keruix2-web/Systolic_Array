# INT8 Systolic Array

A SystemVerilog RTL and verification snapshot of a **4 × 4 weight-stationary systolic array**, developed as a Georgia Tech ECE8804 team project. This export was updated from the local team working folder on November 18, 2026.

## Architecture

| Feature | Implementation |
| --- | --- |
| Processing elements | 16 MAC processing elements in the default 4 × 4 configuration |
| Operands | Signed 8-bit activations and weights |
| Array accumulation | 18-bit partial sums in the default configuration |
| Memory accumulation | Saturation to signed 16 bits between K tiles; final saturation to signed 8 bits |
| Tiling | Rectangular M × K by K × N multiplication, up to 64 × 64 per matrix; dimensions divisible by four |
| Operating modes | Memory, external input, and built-in self-test (BiST) |
| BiST | 64-bit LFSR pattern generation and MISR signature analysis |
| Debug observation | Eight selectable pages for status, tile progress, counters, weight checksum, and sticky event flags |

The controller overlaps the next tile's weight loading with the preceding tile's output drain. Separate read-side and write-side tile counters keep memory addresses and saturation decisions aligned while tiles overlap. PE and buffer enables support internal clock gating during synthesis. The wrapper retains an AND-gated clock, with `en_i` required to remain static during DUT operation.

The RTL is parameterized, but the implementation and post-APR results below are for the **4 × 4** configuration. The reserved FP8 configuration bit does not implement FP8 arithmetic.

## Source layout

| Directory | Contents |
| --- | --- |
| [`src/verilog/matrix_mult/`](src/verilog/matrix_mult/) | Core, wrapper, configuration structures, and parameters |
| [`src/verilog/submodules/`](src/verilog/submodules/) | PE, array, controllers, saturation, delay buffers, and debug observation |
| [`src/verilog/bist/`](src/verilog/bist/) | LFSR, MISR, driver, and signature analyzer |
| [`src/verilog/memory/`](src/verilog/memory/) | Behavioral memory emulators for verification |
| [`src/verilog/misc/`](src/verilog/misc/) | Reset synchronizer |
| [`src/verilog/verif/`](src/verilog/verif/) | Testbenches, tasks, assertion checkers, binds, common packages, and filelists |

Source filenames omit the group suffix; design module names retain `_9`, including `matrix_mult_9` and `matrix_mult_wrapper_9`.

This repository contains **RTL, verification sources, filelists, SDF selection configurations, and this README**. It excludes the C reference simulator, vector-generation scripts, Makefiles, synthesis/APR Tcl, technology libraries, netlists, SDF files, and generated results. The results below describe runs performed in the full project environment, rather than artifacts packaged in this export.

## Verification

The full project uses Synopsys VCS with directed/randomized stimulus, SystemVerilog assertions, memory scoreboards, and C golden-model comparisons. The recorded memory-mode regression contains **174 tests**; the external-mode sequences exercise **106 tiles** per wrapper testbench.

| Testbench | Purpose |
| --- | --- |
| [`tb_matrix_mult.sv`](src/verilog/verif/tb/tb_matrix_mult.sv) | RTL memory-mode tests, tiling, saturation, restart/reset behavior, and debug observation |
| [`tb_matrix_mult_external.sv`](src/verilog/verif/tb/tb_matrix_mult_external.sv) | Core-level external-mode verification |
| [`tb_matrix_mult_gate.sv`](src/verilog/verif/tb/tb_matrix_mult_gate.sv) | Gate-level memory-mode regression through the wrapper |
| [`tb_matrix_mult_wrapper_external.sv`](src/verilog/verif/tb/tb_matrix_mult_wrapper_external.sv) | Direct external-mode wrapper checks |
| [`tb_matrix_mult_wrapper_registered.sv`](src/verilog/verif/tb/tb_matrix_mult_wrapper_registered.sv) | External mode through the driver/monitor registers |
| [`tb_matrix_mult_wrapper_bist.sv`](src/verilog/verif/tb/tb_matrix_mult_wrapper_bist.sv) | LFSR-to-MISR loopback |
| [`tb_matrix_mult_wrapper_full_bist.sv`](src/verilog/verif/tb/tb_matrix_mult_wrapper_full_bist.sv) | Array BiST with an independently computed signature |

RTL regressions bind internal arithmetic and protocol checkers. Gate-level regressions omit those RTL-internal binds and use five suites: gate-level memory, direct external, registered external, BiST loopback, and full BiST. The external wrapper PASS checks at this stage cover row counts and control behavior; their PASS banners alone do not establish arithmetic or timing correctness.

The supplied filelists use basenames and expect a flat simulation working directory. Full memory regressions additionally require generated test vectors from the omitted reference-model flow. Gate-level simulations require the matching netlist, SDF, and licensed standard-cell models. The exported testbenches use an **8 ns clock**; the separate 200 MHz sweep used corresponding **5 ns** testbench clocks.

## Recorded implementation results

The following **November 17, 2026** results used Synopsys Design Compiler, IC Compiler II, and a TSMC 65 nm standard-cell flow. The core dimensions were **259.2 × 172.8 µm**. Slacks are from the six-decimal final routed timing reports after hold repair, with the BC hold uncertainty restored to **50 ps** before reporting and export.

| Target | Clock period | Worst setup slack | Worst hold slack | Physical checks |
| --- | ---: | ---: | ---: | --- |
| 125 MHz | 8 ns | +3.601716 ns | +0.010135 ns | Zero reported routing DRCs, antenna violations, shorts, opens, or placement violations |
| 200 MHz | 5 ns | +0.693848 ns | +0.009950 ns | Zero reported routing DRCs, antenna violations, shorts, opens, or placement violations |

Worst setup was reported at WC/SS, 0.9 V, 125°C; worst hold at BC/FF, 1.1 V, 0°C. TC used TT, 1.0 V, 25°C.

These runs **predate TA commit `4bf9e3a`**, which removes a clock-removal command that discarded clock-uncertainty values. They have not been requalified here under that corrected constraint setup.

## Recorded post-APR simulation results

All five suites were run with SDF annotation and timing checks enabled at each corner using the repaired netlists.

| Target | BC / min delay | TC / typical delay | WC / max delay |
| --- | --- | --- | --- |
| 125 MHz | PASS | PASS | PASS |
| 200 MHz | PASS | PASS | FAIL — timing checks |

At 125 MHz, all **15 suite runs** passed with zero runtime timing violations. Memory mode passed **174/174 tests** at every corner for both frequencies.

At 200 MHz WC, the direct external suite reported **70** timing violations and the registered external suite reported **31**. Their functional checks passed, but the timing regression failed. The logs include both setup-side and hold-side `$setuphold` violations at first-row PE `south_o` registers. The memory and BiST suites reported zero timing violations. **200 MHz is not a fully passing post-APR operating point.**

SDF annotation warnings remain: each suite reported **787 port-not-found warnings at 125 MHz** or **808 at 200 MHz**, plus **10 ignored up-hierarchy delay warnings**. No SDF annotation errors were reported, but the warnings limit annotation completeness. These are pre-silicon tool results, not measured silicon performance.
