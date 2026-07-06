# Changelog

## Branch `add_mem_subsys` (2026-07) — memory subsystem, mret fix, DV material

43 files changed, +3,969 / −33 against `main`.  Commits in order:

| commit | summary |
|---|---|
| `49f0b97` | Memory subsystem RTL + AXI + testbenches + non-DPI tb_top path |
| `2f0b7da` | Fix interrupt-on-mret mepc clobber; add mergesort RTOS test |
| `16e7330` | Add `docs/mem-subsys.md` (block diagram, tutorial, verification story) |
| `ed9cb41` | Answer all eight roadmap labs in `my_lab_ans/` |
| `9cf597e` | Add ten-section DV tutorial in `docs/dv-tutorial/` |
| `2eebd0e` | Add FIFO unit testbench with mirror-model checking |
| `5351434`, `fe00aff` | Generalize `.gitignore` build-dir glob to `obj_dir*/` |

### RTL added — memory subsystem (`49f0b97`)

- `src/AXI/AXI_interface.sv` (+150): `axi_if` SystemVerilog interface —
  full AXI4 burst signals across AW/W/B/AR/R, `master`/`slave` modports,
  parameterized ADDR/DATA/ID widths.  Carries `AWQOS`/`ARQOS`, omits
  `AWPROT`/`ARPROT` (project decision).
- `src/mem_subsys/cache.sv` (+190): parameterized direct-mapped cache
  (default 4KB, 256 × 16B lines) bridging the core's single-beat
  `mem_req_t`/`mem_resp_t` to 4-beat AXI INCR bursts.  `WRITE_BACK=1`:
  write-back/write-allocate D-cache with dirty-eviction write-back;
  `WRITE_BACK=0`: read-only I-cache (write channels tied off).
  8-state FSM: IDLE/LOOKUP/WB_ADDR/WB_DATA/WB_RESP/FILL_ADDR/FILL_DATA/RESP.
- `src/AXI/axi_arbiter.sv` (+242): N-master round-robin AXI arbiter;
  grant held per full burst (no beat interleaving), read and write
  channels arbitrated independently, master index stamped into
  `awid`/`arid`.
- `src/mem_subsys/mem_subsys.sv` (+78): composition — I$ (id 0) + D$
  (id 1) + 2:1 arbiter, exposing CPU-facing imem/dmem ports and one
  `axi_if.master` upward.

### RTL fixed — CPU trap logic (`2f0b7da`)

- `src/mem_stage.sv` (+8/−1): async interrupts are no longer attributed
  to tokens whose side effects already committed in EXE (`FU_CSR` ops and
  `SYS_MRET`).  Previously a timer interrupt landing one cycle after an
  `mret` re-enabled `MIE` was taken *on the mret itself*, writing `mepc`
  with the mret's own PC; FreeRTOS then saved a task context that resumed
  into an infinite mret self-loop (livelock).  The interrupt now stays
  pending and is taken on the next live token with a correct `mepc`.
  Found by the new mergesort RTOS stress test; analysis in
  `docs/mem-subsys.md`.

### Testbenches and test programs

- `tb/axi_dram_model.sv` (+120, `49f0b97`): behavioral AXI4 slave DRAM
  (64KiB word array, INCR bursts, byte strobes), preserving the boot
  trampoline at 0x0/0x4 for `arid == BOOT_ROM_ID`.
- `tb/tb_mem_subsys.sv` (+187, `49f0b97`): directed unit test for the
  memory subsystem — 9 checks covering miss/fill, hit-no-traffic,
  write-allocate, byte-enable merge, dirty eviction write-back, data
  survival across eviction, and concurrent I$/D$ arbitration, with AW/AR
  handshake counters as structural checks.
- `tb/tb_top.sv` (±81, `49f0b97`): non-DPI (`+HEX`) path rewired through
  `mem_subsys` + `axi_dram_model`; DPI (`+ELF`) path untouched.
  `tb/smoke.hex` added as a minimal cache-path boot image.
- `tb/tb_fifo.sv` (+194, `2eebd0e`): unit test for `fifo.sv` against a
  mirror-queue reference model — reset/fill/full-boundary, refused push
  at full, push+pop at full and mid-occupancy, drain/empty, pointer-wrap
  laps, same-cycle flush semantics, 2000-cycle seeded random soak
  (`+SEED=` reproducible), always-on occupancy invariant assertions.
  Mutation-checked: an injected stuck-pointer bug is caught at the first
  wrap lap.
- `my_program/my_mergesort_rtos/` (+302, `2f0b7da`): 3-task FreeRTOS
  stress test (two sorter tasks streaming into a merger via 4-deep
  queues); its block/wake ping-pong sweeps tick-vs-`mret` timing and is
  what exposed the interrupt bug.  Serves as its permanent regression.

### Scripts

- New: `run-mem-subsys-test.sh`, `run-my-mergesort-rtos.sh`,
  `run-fifo-test.sh` (builds/runs DEPTH=4 and the DEPTH=1 `ptr_next`
  corner).
- Modified: `run-riscv-tests.sh`, `run-my-fib.sh`, `run-my-fib-rtos.sh`,
  `run-freertos-demo.sh` — new RTL files added to each `SV_FILES` list.

### Documentation

- `docs/mem-subsys.md` (+312, `16e7330`): block diagram, per-module tour
  (cache FSM, arbiter rules, DRAM model), the interrupt-on-mret bug
  write-up, and the three-layer verification story.
- `my_lab_ans/` (+681, `ed9cb41`): answers to all eight labs in
  `docs/lab-roadmap.md`, questions restated.  Lab 3 includes a real
  forwarding sweep: 58/58 ISA tests in all four `MEM_FORWARDING ×
  WB_FORWARDING` configs; fib cycle counts 191,249 / 191,517 / 193,584 /
  195,182 (identical 59,098-instruction commit traces).
- `docs/dv-tutorial/` (+1,233, `9cf597e`): ten-section design
  verification course taught on this repo's testbenches (mindset,
  testbench anatomy, directed tests, reference models, assertions,
  protocol verification, coverage, regression, debug methodology,
  interview drill with UVM mapping).  Quoted numbers are from real runs:
  Verilator coverage (line 89.7%, fsm_state 20/23 — uncovered = the
  read-only I$'s WB states; `err_q` never toggles = genuine stimulus
  hole) and a mutation run (injected dirty-bit loss caught only by the
  AW traffic counter).
- `README.md`: repository-layout additions, reading-list entries for the
  new docs, and the "No real cache hierarchy" limitation updated to
  describe the `+HEX`-path cache/AXI hierarchy.

### Verification status at branch head

- `run-mem-subsys-test.sh`: all 9 unit checks pass.
- `run-fifo-test.sh`: all phases pass at DEPTH=4 (854 mirror-checked
  pops) and DEPTH=1 (496).
- `run-riscv-tests.sh`: 58/58 (also 58/58 in the three non-default
  forwarding configs).
- `run-my-fib.sh`, `run-my-fib-rtos.sh`, `run-freertos-demo.sh`: pass.
- `run-my-mergesort-rtos.sh`: PASS (pre-fix: livelock timeout at 400k
  cycles).
