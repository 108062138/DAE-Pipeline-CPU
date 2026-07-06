#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERILATOR_BIN="${VERILATOR_BIN:-/opt/verilator/bin/verilator}"
if [[ ! -x "$VERILATOR_BIN" ]]; then
  VERILATOR_BIN="$(command -v verilator)"
fi

SKIP_BUILD="${SKIP_BUILD:-0}"
VERILATOR_PARAMS="${VERILATOR_PARAMS:-}"
SIM_ARGS="${SIM_ARGS:-}"

SV_FILES=(
  "$ROOT/src/fifo.sv"
  "$ROOT/tb/tb_fifo.sv"
)

# Depths to cover: default geometry plus DEPTH=1 (ptr_next special case).
for depth in 4 1; do
  BUILD_DIR="$ROOT/obj_dir_fifo_d${depth}"
  if [[ "$SKIP_BUILD" != "1" ]]; then
    # shellcheck disable=SC2086
    "$VERILATOR_BIN" --binary -sv --assert \
      --Mdir "$BUILD_DIR" \
      -I"$ROOT/include" \
      -GDEPTH=${depth} \
      ${VERILATOR_PARAMS} \
      "${SV_FILES[@]}" \
      --top-module tb_fifo
  fi
  # shellcheck disable=SC2086
  "$BUILD_DIR/Vtb_fifo" ${SIM_ARGS}
done
