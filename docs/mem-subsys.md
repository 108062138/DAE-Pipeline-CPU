# Memory Subsystem: L1 Caches, AXI Arbiter, and AXI DRAM

This note documents the memory subsystem added on the `add_mem_subsys` branch:
a split L1 I-cache / D-cache in front of the core, each acting as an AXI4
burst master, arbitrated onto a single AXI bus that talks to a behavioral DRAM
slave.  It also documents the CPU bug this work uncovered (an interrupt taken
on `mret` corrupting `mepc`) and the verification used to convince ourselves
the design is correct.

For the pipeline itself see `architecture.md`; for signal-level CPU behavior
see `../spec.md`.

## Big Picture

The core has always exposed two single-beat memory ports (`imem` and `dmem`,
`mem_req_t`/`mem_resp_t`).  Before this branch, the testbench answered those
ports directly — either from the Snake SoC DPI model or from a flat `dram[]`
array.  There was no cache and no bus; "memory" responded in one cycle.

This branch inserts a real memory hierarchy between the core and memory:

```text
                    +--------------------------------------------+
                    |                  Top (CPU)                 |
                    |   IF ......................... MEM         |
                    +-----+------------------------------+-------+
                          | imem_req/resp                | dmem_req/resp
                          | (single beat)                | (single beat)
                          v                              v
        +-----------------+------------------------------+-----------------+
        |                 |          mem_subsys          |                 |
        |   +-------------+------------+   +-------------+------------+    |
        |   |   I-cache (read-only)    |   |  D-cache (write-back,    |    |
        |   |   direct-mapped 4KB      |   |  write-allocate)         |    |
        |   |   256 x 16B lines        |   |  direct-mapped 4KB       |    |
        |   +-------------+------------+   +-------------+------------+    |
        |                 | axi_if (master)              | axi_if (master) |
        |                 |    id=0                      |    id=1         |
        |                 v                              v                 |
        |   +------------------------------------------------------+      |
        |   |          axi_arbiter (2 masters -> 1 slave)          |      |
        |   |   round-robin, grant held per burst,                 |      |
        |   |   R and W channels arbitrated independently          |      |
        |   +---------------------------+--------------------------+      |
        +-------------------------------|---------------------------------+
                                        | axi_if (single shared bus)
                                        v
                          +---------------------------+
                          |    axi_dram_model (tb)    |
                          |  behavioral AXI4 slave,   |
                          |  64KiB word array + boot  |
                          |  trampoline at 0x0/0x4    |
                          +---------------------------+
```

Two properties were fixed by earlier project decisions and are preserved here:

- The AXI interface carries full AXI4 burst signals plus `AWQOS`/`ARQOS`
  (kept for future interconnect QoS experiments) but omits `AWPROT`/`ARPROT`.
- Burst geometry is owned by the cache (the bridge), not by the CPU
  microarchitecture package.  `uarch.svh` knows nothing about AXI.

## Where It Sits in the Testbench

`tb_top.sv` has two memory paths selected by plusargs:

- `+ELF=<path>` (**DPI path**): memory is served by the Snake SoC C model,
  which owns the full memory map including uncacheable MMIO (UART, CLINT).
  The memory subsystem is instantiated but its request inputs are masked
  (`req_valid && !use_dpi`), so it stays idle.  All existing software tests
  (riscv-tests, fib, FreeRTOS apps) use this path and are unaffected.
- `+HEX=<path>` (**AXI path**): memory is served by
  `mem_subsys` + `axi_dram_model`.  The `.hex` image is loaded into the DRAM
  array with `$readmemh`, and every instruction fetch and data access flows
  through the caches and the AXI bus.

The split exists because the DPI model routes accesses to *devices*, and
device registers must not be cached.  Merging the two paths (cacheable DRAM
window + uncacheable MMIO window in front of the DPI model) is future work.

## Module Tour

### `src/AXI/AXI_interface.sv` — `axi_if`

A SystemVerilog `interface` holding the five AXI4 channels as flat signals,
grouped AW / W / B / AR / R, with `master` and `slave` modports.  Parameters:
`ADDR_WIDTH=32`, `DATA_WIDTH=32`, `ID_WIDTH=4`.  Full burst signaling
(`awlen/awsize/awburst/awlock/awcache/awqos`, `wlast`, mirrored on the read
side, `rlast`).  No `AWPROT`/`ARPROT`.

### `src/mem_subsys/cache.sv` — parameterized direct-mapped cache

One module serves as both caches:

- `WRITE_BACK=1` (D-cache): write-back, write-allocate.
- `WRITE_BACK=0` (I-cache): read-only; the AW/W/B logic is disabled and the
  write channels are tied off.

Default geometry, tunable by parameter:

```text
NUM_LINES=256, LINE_WORDS=4  ->  4KB, 16-byte lines

  31            12 11         4 3    2 1  0
 +----------------+------------+------+----+
 |    tag (20b)   | index (8b) | word | 00 |
 +----------------+------------+------+----+
```

The CPU-facing side speaks the same single-beat `mem_req_t`/`mem_resp_t`
protocol the pipeline already uses, so `Top.sv` and the stages needed no
changes.  The AXI-facing side issues 4-beat INCR bursts
(`arlen/awlen=3`, `arsize/awsize=3'b010`).

The control FSM is deliberately simple and single-outstanding, matching the
`req_sent_q` style already used in `mem_stage.sv`:

```text
        req_valid                    hit
IDLE ------------> LOOKUP ---------------------------> RESP --> IDLE
                     |                                   ^
                     | miss, victim clean/invalid        |
                     +----------------> FILL_ADDR        |
                     |                      |            |
                     | miss, victim dirty   v            |
                     +--> WB_ADDR      FILL_DATA --------+ (re-LOOKUP, now hit)
                              |             ^
                              v             |
                          WB_DATA --> WB_RESP
```

Key behaviors:

- **Read hit / write hit**: 3 cycles (IDLE→LOOKUP→RESP).  A write hit merges
  bytes under `be[3:0]` and sets the line's dirty bit.  No AXI traffic.
- **Miss, clean victim**: AR burst fills the line, then LOOKUP retries and
  hits.
- **Miss, dirty victim** (D-cache only): the old line is written back first
  (AW, 4 W beats, B), using the *victim's* tag to form the address; then the
  fill proceeds.
- **Write miss**: allocate — fill the line from memory, then merge the write
  into the freshly filled line (write-allocate).
- Bus errors (`rresp[1]`/`bresp[1]`) are accumulated and surfaced as
  `resp.error`, which the core already turns into a bus-error halt.

### `src/AXI/axi_arbiter.sv` — N:1 round-robin arbiter

Funnels `NUM_MASTERS` (here 2) `axi_if` masters onto one slave-side bus.
Three rules define it:

1. **Grant per burst, not per beat.**  A write grant is held from AW through
   the last W beat and the B response; a read grant is held from AR through
   `rlast`.  Interleaving beats of different masters is never allowed.
2. **Independent read/write arbitration.**  The R and W channel groups have
   separate FSMs and rotate pointers, so an I-cache fill can proceed in
   parallel with a D-cache write-back.
3. **ID stamping.**  The winning master's index is written into `awid`/`arid`
   (I-cache=0, D-cache=1), so the slave side can identify the source.

### `src/mem_subsys/mem_subsys.sv` — composition

Instantiates the two caches and the arbiter, exposes the two CPU-facing
request/response ports plus one `axi_if.master` upward.  QoS values are inputs
(`imem_qos_i=0`, `dmem_qos_i=1` in the testbench) and are just forwarded into
`awqos`/`arqos` — reserved for future interconnect experiments.

### `tb/axi_dram_model.sv` — behavioral AXI4 slave (simulation only)

A word-addressed `logic [31:0] mem[MEM_WORDS]` array (64KiB default) behind a
minimal AXI4 slave FSM: accepts AW then up to `awlen+1` W beats with byte
strobes, responds B; accepts AR and streams `arlen+1` R beats with `rlast` on
the final beat.  Upper address bits wrap, matching the old flat `dram[]`
indexing.

It preserves the old reset-vector special case: reads with
`arid == BOOT_ROM_ID` (the I-cache's ID) at byte addresses 0x0/0x4 return the
boot trampoline (`lui x1, 0x80000; jalr x0, 0(x1)`), so a `+HEX` image linked
at 0x80000000 still boots.  This lives in `tb/`, not `src/` — it is a test
fixture, not synthesizable RTL.

## The Bug This Work Found: Interrupt Taken on `mret`

The new `my_mergesort_rtos` test (three FreeRTOS tasks: two sorters streaming
into a merger through queues) hung after printing `sorted[0] = 1`.  The commit
trace showed the CPU spinning forever on a single instruction — the `mret` at
the end of the FreeRTOS trap handler.

The failure chain:

```text
cycle N   : mret is in EXE. mret_commit fires; CSRFile will set
            mstatus.MIE <= MPIE (=1) at the next clock edge.
cycle N+1 : the SAME mret token is now in MEM. mem_stage checks
            "mstatus.MIE && mie & mip" -- MIE is already 1, MTIP is
            pending, so it takes the interrupt ON THE MRET TOKEN:
            mepc <= mem_q.ir.pc = the mret's own address.
          : FreeRTOS's handler saves that mepc as the task's resume PC.
later     : the task is resumed: csrw mepc, <mret addr>; mret
            -> mret jumps to itself -> executes mret again -> forever.
            Every timer tick re-saves the same corrupted context.
```

Architecturally this can never happen: inside the handler `MIE=0`, and the
`mret` is the very instruction that re-enables interrupts, so a pending
interrupt must be taken on the mret's *target*, never on the mret itself.

The same one-cycle window also existed for CSR writes: a `csrrw` that enables
interrupts commits its CSR side effect in EXE; trapping on it in MEM makes it
re-execute after the handler returns, double-applying the write (fatal for
swap-style `csrrw`).

**Fix** (`src/mem_stage.sv`): async interrupts are suppressed for tokens whose
side effects already committed in EXE — `fu_type == FU_CSR` or
`sys_kind == SYS_MRET`.  The interrupt level stays pending and is taken on the
next live token, with a correct `mepc`.  This costs at most one instruction of
interrupt latency and cannot starve: real code does not execute unbounded
CSR/MRET streams.

Note `freertos_demo` had been passing all along — a tick had simply never
lined up with an `mret` commit.  Timing-sensitive bugs need workloads that
sweep timing; that is exactly what the queue ping-pong in the mergesort test
does.

## Verification

Three layers, from component-level determinism up to whole-system stress.

### 1. Directed unit test: `tb_mem_subsys.sv`

```sh
./scripts/run-mem-subsys-test.sh
```

Instantiates only `mem_subsys` + `axi_dram_model` (no CPU) and drives
`mem_req_t` stimulus directly.  Alongside data checks it counts AW/AR
handshakes at the DRAM boundary, so caching behavior is verified structurally,
not just functionally — a cache that "works" by going to memory every time
fails the traffic counts.  Checks, in order:

1. I$ read miss fills a line and returns the boot-trampoline word
   (exactly 1 AR burst).
2. I$ hit on the same line returns data with **zero** new AXI traffic.
3. I$ fetch at `0x8000_0000` wraps to `mem[0]` and does not see the
   trampoline (ID/address gating of the boot ROM special case).
4. D$ write miss allocates: issues an AR fill, **no** AW (write-back means no
   write-through traffic).
5. D$ read hit returns the merged write data with no AXI traffic.
6. Partial-word store (`be=0010`) merges only the addressed byte lane.
7. A conflicting read (same index, different tag) evicts the dirty line:
   exactly one AW (write-back) plus one AR (fill).
8. Re-reading the evicted address refills from DRAM and returns the
   written-back data — the round trip proves wlast/beat ordering and strobes.
9. Concurrent I$ and D$ misses (forked) are both served — the arbiter
   grants both bursts without loss or interleave corruption.

The testbench self-checks with `$fatal` and has a watchdog timeout.

### 2. Regression: nothing existing may change

The mem_subsys files are compiled into every simulator build, and the
`mem_stage.sv` interrupt fix touches the core proper, so the full suite is
re-run:

```sh
./scripts/run-riscv-tests.sh      # 58/58 rv32ui/rv32mi ISA tests
./scripts/run-my-fib.sh           # bare-metal C, fib(19)=4181
./scripts/run-my-fib-rtos.sh      # FreeRTOS, 2 tasks + queue
./scripts/run-freertos-demo.sh    # FreeRTOS, preemption/tick demo
```

Notably `rv32mi-p-*` covers the trap/CSR paths the interrupt fix touches, and
the two pre-existing FreeRTOS apps confirm the fix does not disturb working
interrupt-driven scheduling.

### 3. System stress: `my_mergesort_rtos`

```sh
./scripts/run-my-mergesort-rtos.sh
```

Three tasks under preemptive FreeRTOS: `SortL` and `SortR` (priority 2) each
mergesort half of a 16-element array, then stream elements into two 4-deep
queues; `Merge` (priority 1) pulls whichever queue has the smaller head,
verifies global sortedness, and halts with the pass/fail exit code.  The
shallow queues force constant block/wake transitions, so context switches and
`mret` commits sweep across tick timing — this is the workload that exposed
the interrupt-on-mret bug, and it now serves as its regression test.

The testbench asserts on timeout, so a livelock (like the original bug) is a
loud failure, not a silent pass.

### Manual sanity: the AXI path under the real core

The unit test drives the subsystem without a CPU; to see the core itself fetch
and run through the caches, build any `+HEX` image and run without `+ELF`:

```sh
obj_dir_dae/Vtb_top +HEX=tb/smoke.hex +MAX_CYCLES=200
```

`tb/smoke.hex` is a minimal image checked in for this purpose.

## Current Limitations / Next Steps

- Single-outstanding per cache; no pipelining of fills behind hits.
- Direct-mapped only; no associativity.
- No cache maintenance operations (`fence.i` does not invalidate the I$ —
  fine today because the `+HEX` path runs no self-modifying code).
- The DPI (`+ELF`) path bypasses the caches entirely; unifying the two paths
  requires an uncacheable MMIO window in front of the DPI model.
- The arbiter serializes at burst granularity; a crossbar with per-slave
  routing (see the interconnect-topology plans) is the natural evolution.
