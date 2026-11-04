# Systolic Array

A SystemVerilog implementation of a **4 × 4 weight-stationary systolic array** for matrix multiplication, developed as an ECE8804 team project.

The design uses signed 8-bit inputs and weights, supports tiled matrix multiplication up to 64 × 64 for dimensions divisible by four, and accumulates partial sums with saturation. It includes memory and external-input operating modes, built-in self-test (BiST), and debug observation outputs.

The repository also contains a C reference simulator, SystemVerilog testbenches, assertion checkers, and build Makefiles.

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
