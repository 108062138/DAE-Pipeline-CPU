#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERILATOR_BIN="${VERILATOR_BIN:-/opt/verilator/bin/verilator}"
if [[ ! -x "$VERILATOR_BIN" ]]; then
  VERILATOR_BIN="$(command -v verilator)"
fi

BUILD_DIR="${BUILD_DIR:-$ROOT/obj_dir_dae}"
SOC_BUILD="${SOC_BUILD:-$ROOT/build}"
MY_FIB_BUILD="${MY_FIB_BUILD:-$ROOT/build/my_fib}"
MY_FIB_ELF="${MY_FIB_ELF:-$MY_FIB_BUILD/my_fib}"
MAX_CYCLES="${MAX_CYCLES:-200000}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_MY_FIB_BUILD="${SKIP_MY_FIB_BUILD:-0}"

if [[ ! -d "$SOC_BUILD" ]]; then
  echo "Missing Snake SoC build directory: $SOC_BUILD" >&2
  echo "Run: cmake -S . -B build && cmake --build build -j" >&2
  exit 1
fi

SV_FILES=(
  "$ROOT/src/fifo.sv"
  "$ROOT/src/regfile.sv"
  "$ROOT/src/decoder.sv"
  "$ROOT/src/scoreboard.sv"
  "$ROOT/src/alu.sv"
  "$ROOT/src/branch_unit.sv"
  "$ROOT/src/CSRFile.sv"
  "$ROOT/src/lsu.sv"
  "$ROOT/src/load_data_filter.sv"
  "$ROOT/src/if_stage.sv"
  "$ROOT/src/id_stage.sv"
  "$ROOT/src/frontend.sv"
  "$ROOT/src/exe_stage.sv"
  "$ROOT/src/mem_stage.sv"
  "$ROOT/src/wb_stage.sv"
  "$ROOT/src/backend.sv"
  "$ROOT/src/AXI/AXI_interface.sv"
  "$ROOT/src/AXI/axi_arbiter.sv"
  "$ROOT/src/mem_subsys/cache.sv"
  "$ROOT/src/mem_subsys/mem_subsys.sv"
  "$ROOT/src/Top.sv"
  "$ROOT/tb/axi_dram_model.sv"
  "$ROOT/tb/tb_top.sv"
  "$ROOT/dpi/snake_soc_dpi.c"
)

CFLAGS="-I$ROOT/dpi"
CFLAGS+=" -I$ROOT/snake_soc/include"
CFLAGS+=" -I$ROOT/devices/common/include"
CFLAGS+=" -I$ROOT/devices/boot_rom/include"
CFLAGS+=" -I$ROOT/devices/uart/include"
CFLAGS+=" -I$ROOT/devices/dram/include"
CFLAGS+=" -I$ROOT/devices/clint/include"
CFLAGS+=" -I$ROOT/devices/irq_agg/include"
CFLAGS+=" -I$ROOT/elf_loader/include"

LDFLAGS="$SOC_BUILD/snake_soc/libsnake_soc.a"
LDFLAGS+=" $SOC_BUILD/_devices/boot_rom/libdevices_boot_rom.a"
LDFLAGS+=" $SOC_BUILD/_devices/clint/libdevices_clint.a"
LDFLAGS+=" $SOC_BUILD/_devices/uart/libdevices_uart.a"
LDFLAGS+=" $SOC_BUILD/_devices/dram/libdevices_dram.a"
LDFLAGS+=" $SOC_BUILD/_devices/irq_agg/libdevices_irq_agg.a"
LDFLAGS+=" $SOC_BUILD/_elf_loader/libelf_loader.a"
LDFLAGS+=" $SOC_BUILD/_devices/common/libdevices_common.a"

if [[ "$SKIP_MY_FIB_BUILD" != "1" ]]; then
  cmake -S "$ROOT/my_program/my_fib" -B "$MY_FIB_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/runtime/toolchain.cmake"
  cmake --build "$MY_FIB_BUILD" -j
fi

if [[ ! -f "$MY_FIB_ELF" ]]; then
  echo "Missing my_fib ELF: $MY_FIB_ELF" >&2
  exit 1
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  "$VERILATOR_BIN" --binary -sv \
    --Mdir "$BUILD_DIR" \
    -I"$ROOT/include" \
    "${SV_FILES[@]}" \
    --top-module tb_top \
    -CFLAGS "$CFLAGS" \
    -LDFLAGS "$LDFLAGS"
fi

SIM="$BUILD_DIR/Vtb_top"
if [[ ! -x "$SIM" ]]; then
  echo "Missing simulator binary: $SIM" >&2
  exit 1
fi

"$SIM" +ELF="$MY_FIB_ELF" +MAX_CYCLES="$MAX_CYCLES" +QUIET
