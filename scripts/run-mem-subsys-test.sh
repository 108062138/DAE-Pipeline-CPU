#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERILATOR_BIN="${VERILATOR_BIN:-/opt/verilator/bin/verilator}"
if [[ ! -x "$VERILATOR_BIN" ]]; then
  VERILATOR_BIN="$(command -v verilator)"
fi

BUILD_DIR="${BUILD_DIR:-$ROOT/obj_dir_mem_subsys}"
SKIP_BUILD="${SKIP_BUILD:-0}"
VERILATOR_PARAMS="${VERILATOR_PARAMS:-}"

SV_FILES=(
  "$ROOT/src/AXI/AXI_interface.sv"
  "$ROOT/src/AXI/axi_arbiter.sv"
  "$ROOT/src/mem_subsys/cache.sv"
  "$ROOT/src/mem_subsys/mem_subsys.sv"
  "$ROOT/tb/axi_dram_model.sv"
  "$ROOT/tb/tb_mem_subsys.sv"
)

if [[ "$SKIP_BUILD" != "1" ]]; then
  # shellcheck disable=SC2086
  "$VERILATOR_BIN" --binary -sv \
    --Mdir "$BUILD_DIR" \
    -I"$ROOT/include" \
    ${VERILATOR_PARAMS} \
    "${SV_FILES[@]}" \
    --top-module tb_mem_subsys
fi

SIM="$BUILD_DIR/Vtb_mem_subsys"
if [[ ! -x "$SIM" ]]; then
  echo "Missing simulator binary: $SIM" >&2
  exit 1
fi

"$SIM"
