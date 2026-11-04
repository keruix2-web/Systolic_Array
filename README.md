# Systolic Array

A SystemVerilog implementation of a **4 × 4 weight-stationary systolic array** for matrix multiplication, developed as an ECE8804 team project.

The design uses signed 8-bit inputs and weights, supports tiled matrix multiplication up to 64 × 64 for dimensions divisible by four, and accumulates partial sums with saturation. It includes memory and external-input operating modes, built-in self-test (BiST), and debug observation outputs.

The repository also contains a C reference simulator, SystemVerilog testbenches, assertion checkers, and build Makefiles.

## Performance and implementation results

Results below are from the November 1, 2026 runs using a TSMC 65 nm standard-cell flow, Synopsys Design Compiler for synthesis, IC Compiler II for APR, and VCS for simulation. The design was constrained and simulated at **8 ns (125 MHz)**; this is the tested clock frequency, not a measured maximum frequency.

| Metric | Synthesis | Post-APR |
| --- | ---: | ---: |
| Cell area | 27,003.96 µm² | 26,488.08 µm² |
| Worst reported setup slack | +4.10 ns | +1.40 ns |
| Worst reported hold slack | +0.06 ns | +0.01 ns |
| Core dimensions | — | 259.2 × 172.8 µm |
| Core area | — | 44,789.76 µm² |
| Core utilization | — | 59.14% |

Synthesis completed and exported the gate-level netlist and timing files. APR completed placement, clock-tree optimization, routing, physical checks, and output export. Final APR reports showed zero constraint violations, routing DRCs, antenna violations, shorts, or open nets, and the placement legality check passed. Its final GUI-launch command failed because no display was available, after the implementation outputs had been saved.

## Simulation results

| Verification stage | Max-delay SDF | Min-delay SDF |
| --- | --- | --- |
| Post-synthesis | All 5 suites passed | All 5 suites passed |
| Post-APR | All 5 suites passed | All 5 suites passed |

Each regression includes the memory-mode testbench and four wrapper suites: direct external input, registered external input, BiST loopback, and full BiST. The memory suite passed **174/174 tests** in every run, including the debug observation checks. No runtime timing violations were reported. Debug-page reads allow one clock period for the output to settle before comparison.

These passes retain timing-model limitations: post-synthesis compilation reported 264 negative-limit SDF warnings per suite, and post-APR compilation reported 1,030 port-not-found and 10 ignored up-hierarchy delay warnings per suite. Some timing annotations are therefore incomplete. Synthesis also retained transition/fanout and leakage-objective constraint entries. The results summarize the checks performed by the supplied flow and do not constitute independent silicon signoff.

## Repository layout

| Folder | Contents |
| --- | --- |
| `src/verilog/` | RTL, testbenches, and verification checkers |
| `src/Simulator/` | C reference model and supporting tests |
| `src/Makefiles/` | Simulation, synthesis, and APR Makefiles |
| `img/` | Architecture diagrams and waveform illustrations |
| `sim/` | Behavioral and gate-level simulation entry points |
| `syn/`, `apr/` | Synthesis and physical-design entry points |

This public snapshot omits the synthesis and APR TCL scripts: `src/syn/` and `src/apr/` contain directory placeholders only. Full synthesis and APR runs require those scripts and the appropriate EDA tools and technology libraries.

See [the RTL documentation](src/verilog/README.md) for design details and [the verification documentation](src/verilog/verif/README.md) for the testbench structure.
