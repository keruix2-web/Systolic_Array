#!/bin/bash
# ./run.sh <Num Array Rows> <Num Array Cols> <Matrix M> <Matrix N> <Matrix K> \
#           <Path to Input Matrix A> <Path to Weight Matrix B> <Path to Write Output Matrix C>

set -e

if [ "$#" -ne 8 ]; then
    echo "Usage: $0 <rows> <cols> <M> <N> <K> <A path> <B path> <C path>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/sim.out"

# Use the prebuilt binary if it is included, otherwise build it from source
if [ ! -x "$BIN" ]; then
    make -s -C "$SCRIPT_DIR" >&2
fi
"$BIN" "$@"
