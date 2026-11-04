# Verification

SystemVerilog testbenches and assertion checkers for the systolic array core and wrapper. They cover memory and external-input modes, tiling, saturation, reset and restart behavior, BiST, and debug observation outputs.

Testbenches are organized under `tb/`, shared tasks under `tasks/`, assertions under `checkers/`, and bindings and file lists under `binds/` and `filelists/`. Gate-level testbenches support post-synthesis and post-APR verification.
