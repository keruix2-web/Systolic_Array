# Systolic Array RTL

SystemVerilog RTL for a 4 × 4 weight-stationary systolic array using signed 8-bit inputs and weights. Tiling supports matrix dimensions up to 64 × 64 in multiples of four, with partial-sum accumulation and saturation.

The design includes a controller, processing elements, memory interfaces, an external-input mode, built-in self-test (BiST), and debug observation outputs. The `verif/` folder contains testbenches and checkers.
