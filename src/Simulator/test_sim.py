#!/usr/bin/env python3
"""
Regression tests for the systolic array simulator.

Runs ./run.sh on many generated (A, B) pairs and compares the output C file
against a numpy reference model that applies the same saturation rules as the
hardware spec (partial sum and output saturation)

Usage:
  python3 test_sim.py            # run the full suite
  python3 test_sim.py --quick    # smaller sweep
  python3 test_sim.py --seed 7   # reproducible random cases
  python3 test_sim.py --keep     # keep failing cases in ./failed_cases
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RUN_SH = os.path.join(SCRIPT_DIR, "run.sh")
EXAMPLES_DIR = os.path.join(SCRIPT_DIR, "..", "..", "doc", "examples")

OUT_BITS = 8
PSUM_BITS = 16


def sat(x, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return np.clip(x, lo, hi)


def reference_gemm(A, B, pe_rows):
    """Golden model: per-K-tile full precision, int16 psum saturation, int8 output."""
    M, K = A.shape
    _, N = B.shape
    psum = np.zeros((M, N), dtype=np.int64)
    for k in range(0, K, pe_rows):
        tile = A[:, k:k + pe_rows].astype(np.int64) @ B[k:k + pe_rows, :].astype(np.int64)
        psum = sat(psum + tile, PSUM_BITS)
    return sat(psum, OUT_BITS)


def write_matrix(path, m):
    with open(path, "w") as f:
        for row in m:
            f.write(" ".join(f"{int(v) & 0xFF:02X}" for v in row) + "\n")


def read_matrix(path, rows, cols):
    with open(path) as f:
        vals = [int(tok, 16) for tok in f.read().split()]
    if len(vals) != rows * cols:
        raise ValueError(f"{path}: expected {rows * cols} elements, got {len(vals)}")
    arr = np.array(vals, dtype=np.int64).reshape(rows, cols)
    return np.where(arr >= 128, arr - 256, arr)


def run_sim(pe_rows, pe_cols, A, B, workdir):
    M, K = A.shape
    N = B.shape[1]
    a_path = os.path.join(workdir, "A.txt")
    b_path = os.path.join(workdir, "B.txt")
    c_path = os.path.join(workdir, "C.txt")
    write_matrix(a_path, A)
    write_matrix(b_path, B)
    if os.path.exists(c_path):
        os.remove(c_path)
    proc = subprocess.run(
        [RUN_SH, str(pe_rows), str(pe_cols), str(M), str(N), str(K), a_path, b_path, c_path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"run.sh exited {proc.returncode}: {proc.stderr.strip()}")
    return read_matrix(c_path, M, N)


class Runner:
    def __init__(self, keep):
        self.passed = 0
        self.failed = []
        self.keep = keep
        self.workdir = tempfile.mkdtemp(prefix="systolic_test_")

    def check(self, name, pe_rows, pe_cols, A, B, expected=None):
        if expected is None:
            expected = reference_gemm(A, B, pe_rows)
        try:
            got = run_sim(pe_rows, pe_cols, A, B, self.workdir)
            ok = np.array_equal(got, expected)
            detail = "" if ok else self._diff(got, expected)
        except Exception as e:  # noqa: BLE001
            ok, detail = False, str(e)

        if ok:
            self.passed += 1
        else:
            self.failed.append(name)
            print(f"FAIL {name}\n{detail}")
            if self.keep:
                self._save(name, pe_rows, pe_cols, A, B, expected)

    @staticmethod
    def _diff(got, expected):
        bad = np.argwhere(got != expected)
        lines = [f"  {len(bad)} mismatching elements, first few:"]
        for r, c in bad[:5]:
            lines.append(f"    C[{r}][{c}] got {got[r, c]} expected {expected[r, c]}")
        return "\n".join(lines)

    def _save(self, name, pe_rows, pe_cols, A, B, expected):
        d = os.path.join(SCRIPT_DIR, "failed_cases", name.replace(" ", "_"))
        os.makedirs(d, exist_ok=True)
        write_matrix(os.path.join(d, "A.txt"), A)
        write_matrix(os.path.join(d, "B.txt"), B)
        write_matrix(os.path.join(d, "C_expected.txt"), expected)
        M, K = A.shape
        with open(os.path.join(d, "cmd.txt"), "w") as f:
            f.write(f"./run.sh {pe_rows} {pe_cols} {M} {B.shape[1]} {K} {d}/A.txt {d}/B.txt {d}/C.txt\n")

    def cleanup(self):
        shutil.rmtree(self.workdir, ignore_errors=True)


def rand_mat(rng, rows, cols, lo=-128, hi=127):
    return rng.integers(lo, hi + 1, size=(rows, cols), dtype=np.int64)


def test_examples(r):
    if not os.path.isdir(EXAMPLES_DIR):
        print(f"Skipping provided examples: {EXAMPLES_DIR} not found")
        return
    for tag, n in (("2", 4), ("8", 8)):
        A = read_matrix(os.path.join(EXAMPLES_DIR, f"A_matrix_{tag}.txt"), n, n)
        B = read_matrix(os.path.join(EXAMPLES_DIR, f"B_matrix_{tag}.txt"), n, n)
        gold = read_matrix(os.path.join(EXAMPLES_DIR, f"C_GOLD_matrix_{tag}.txt"), n, n)
        r.check(f"example_{tag}", 4, 4, A, B, expected=gold)


def test_directed(r):
    # Extreme values: -128*-128 = 16384 is the largest product; 4 of them overflow int16
    for a_val, b_val in ((-128, -128), (127, 127), (-128, 127), (127, -128), (0, 127)):
        A = np.full((8, 16), a_val, dtype=np.int64)
        B = np.full((16, 8), b_val, dtype=np.int64)
        r.check(f"const A={a_val} B={b_val}", 4, 4, A, B)

    # Partial sum saturation changes the answer vs. full precision:
    # K tile 0 sums to +65536 (saturates to 32767), K tile 1 sums to -32768 -> final -1.
    # Full precision would be +32768 -> 127, so this catches a missing int16 psum clamp.
    A = np.full((4, 8), -128, dtype=np.int64)
    B = np.zeros((8, 4), dtype=np.int64)
    B[0:4, :] = -128    # tile 0: 4 * 16384 = 65536
    B[4:8, :] = 64      # tile 1: 4 * -8192 = -32768
    expected = reference_gemm(A, B, 4)
    assert expected[0, 0] != sat(A @ B, 8)[0, 0], "directed psum test is not discriminating"
    r.check("psum_int16_saturation", 4, 4, A, B)

    # Identity / permutation checks that make data movement bugs obvious
    for n in (4, 8, 16):
        I = np.eye(n, dtype=np.int64)
        P = np.eye(n, dtype=np.int64)[::-1]
        r.check(f"identity_{n}", 4, 4, I, P)
        r.check(f"perm_{n}", 4, 4, P, rand_mat(np.random.default_rng(n), n, n))

    # Maximum supported size
    rng = np.random.default_rng(64)
    r.check("max_64x64_small_vals", 4, 4, rand_mat(rng, 64, 64, -3, 3), rand_mat(rng, 64, 64, -3, 3))
    r.check("max_64x64_full_range", 4, 4, rand_mat(rng, 64, 64), rand_mat(rng, 64, 64))


def test_random(r, rng, quick):
    array_shapes = [(4, 4), (2, 2), (4, 2), (2, 4), (8, 8), (1, 1), (3, 5)]
    trials = 3 if quick else 10
    for pe_rows, pe_cols in array_shapes:
        for t in range(trials):
            max_mult = max(1, 64 // max(pe_rows, pe_cols))
            M = pe_rows * int(rng.integers(1, min(max_mult, 6) + 1))
            K = pe_rows * int(rng.integers(1, min(max_mult, 6) + 1))
            N = pe_cols * int(rng.integers(1, min(max_mult, 6) + 1))
            # Small values keep results in int8 range so arithmetic bugs aren't hidden by saturation;
            # full range values exercise both saturation stages.
            for lo, hi, tag in ((-4, 4, "small"), (-128, 127, "full")):
                A = rand_mat(rng, M, K, lo, hi)
                B = rand_mat(rng, K, N, lo, hi)
                r.check(f"rand_{tag}_{pe_rows}x{pe_cols}_M{M}_N{N}_K{K}_{t}", pe_rows, pe_cols, A, B)


def test_bad_args(r):
    # M, N, K not multiples of the array size must be rejected
    for args in (["4", "4", "6", "4", "4"], ["4", "4", "4", "6", "4"], ["4", "4", "4", "4", "6"]):
        proc = subprocess.run([RUN_SH, *args, "a", "b", "c"], capture_output=True, text=True)
        name = f"reject_args_{'_'.join(args)}"
        if proc.returncode != 0:
            r.passed += 1
        else:
            r.failed.append(name)
            print(f"FAIL {name}: run.sh accepted invalid dimensions")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--keep", action="store_true", help="save failing cases to ./failed_cases")
    args = ap.parse_args()

    # Build once up front so build errors show clearly
    subprocess.run(["make", "-s", "-C", SCRIPT_DIR], check=True)

    r = Runner(args.keep)
    try:
        test_examples(r)
        test_directed(r)
        test_random(r, np.random.default_rng(args.seed), args.quick)
        test_bad_args(r)
    finally:
        r.cleanup()

    total = r.passed + len(r.failed)
    print(f"\n{r.passed}/{total} passed")
    sys.exit(0 if not r.failed else 1)


if __name__ == "__main__":
    main()
