# Lab 8 Answers: Future Extension Project

The roadmap offers six directions.  This answer documents the extension
actually built on the `add_mem_subsys` branch — a real memory hierarchy —
which is in the spirit of the list (it is the prerequisite that makes
several of the listed options meaningful), plus notes on the listed options
and what building the extension taught about them.

## What was built

**CPU ↔ split L1 I$/D$ ↔ AXI arbiter ↔ AXI DRAM**, full write-up in
`docs/mem-subsys.md`:

- `src/AXI/AXI_interface.sv` — AXI4 burst interface (master/slave modports).
- `src/mem_subsys/cache.sv` — one parameterized direct-mapped cache
  (4KB, 16B lines): `WRITE_BACK=1` gives the write-back/write-allocate
  D-cache, `WRITE_BACK=0` strips the write path for the read-only I-cache.
- `src/AXI/axi_arbiter.sv` — N:1 round-robin, grant held per burst,
  independent read/write arbitration.
- `tb/axi_dram_model.sv` — behavioral AXI4 slave for simulation.
- Verified by a directed unit test that counts AXI transactions
  (`./scripts/run-mem-subsys-test.sh`), the full ISA regression, and a new
  FreeRTOS stress test (`./scripts/run-my-mergesort-rtos.sh`).

The core did not change at all to gain the hierarchy — the latency-blind
`mem_req_t`/`mem_resp_t` handshake and the epoch-based response filtering
(Labs 5 and 7) absorbed multi-cycle variable latency as designed.  That is
the strongest validation of the token architecture this repo has produced.

## What it taught: the token fields earn their keep

The project surfaced a genuine, subtle CPU bug — exactly the kind Lab 8 is
meant to make you appreciate.  The stress test hung: a timer interrupt was
taken *on the `mret` token in MEM*, one cycle after `mret` had already
re-enabled `MIE` from EXE, so trap entry wrote `mepc` with the mret's own
PC and FreeRTOS saved a task context that resumed into an infinite
`mret`-to-itself loop.

Root cause in one sentence: **an instruction whose side effects commit in
EXE must not be re-attributed as "not yet executed" by trap logic in MEM.**
The fix (in `mem_stage.sv`) suppresses async-interrupt attribution for
`FU_CSR`/`SYS_MRET` tokens; the interrupt stays pending and lands on the
next live token.  Full story: `docs/mem-subsys.md`.

## The listed options, with hindsight

- **Move CSR writes to a unified commit boundary** — the mret bug is the
  strongest argument for this one.  The bug class exists *only because* CSR
  side effects commit in EXE while trap attribution happens in MEM; with a
  single commit boundary there is no window in which "already executed" and
  "can still trap" disagree.  Recommended as the next project.
- **Move stores into a committed store buffer** — same theme from the other
  side (Lab 6 Q3): stores are gated in MEM precisely because they commit
  early.  A store buffer would drain after WB and remove the same-cycle
  gating.  It also unlocks miss-under-store overlap on the new D-cache,
  which currently serializes.
- **Replace stage-row scoreboard with producer tags** — the Lab 3
  measurements show why: the stage-row design can only forward from two
  fixed windows (MEM/WB rows), and its entire benefit measured ~2%.
  Producer tags decouple "who makes the value" from "which stage register it
  happens to occupy."
- **Add a small branch predictor** — every taken branch and every JAL
  currently redirects (Lab 4).  With the I-cache in place, fetch is cheap
  on hits, so redirect latency is now the dominant frontend cost; a BTB
  would attack it directly.
- **Age-based event arbitration using `seq_id_t`** — the backend already
  resolves same-cycle events by stage position (MEM trap beats EXE
  redirect).  `seq_after()` would make that priority explicit and
  order-based, which becomes mandatory once events can be raised
  out of order.
- **Expand trap behavior toward the full privileged spec** — the halts
  table (Lab 6 Q2) is the worklist: illegal instruction and misaligned
  accesses would become real traps with handlers, and `mstatus`/delegation
  would grow toward S-mode.

The closing point of the roadmap holds: every one of these projects leans on
`epoch`/`seq_id`/`killed` already being in every token.  The memory
subsystem project proved those fields correct under latency; the
commit-boundary projects would prove them correct under side-effect
ordering.
