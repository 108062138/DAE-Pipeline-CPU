# Lab 6 Answers: CSR, Traps, And Halt Model

Files studied: `src/CSRFile.sv`, trap logic in `src/mem_stage.sv`, commit
packet generation in `src/wb_stage.sv`.

## Q1. Which events are modeled as traps?

Traps are events the *software stack is expected to handle*: they redirect
to `mtvec` with `mepc/mcause/mtval` written and `MIE` stacked into `MPIE`,
and execution continues.  In `mem_stage.sv`:

- **Asynchronous interrupts**, taken only when `mstatus.MIE` is set and the
  corresponding `mie & mip` bit is pending, prioritized external > software
  > timer (causes `0x8000000b`, `0x80000003`, `0x80000007`).  These are
  level signals from the platform (CLINT/IRQ aggregator via the DPI bridge).
- **ECALL** (cause 11) — the one synchronous exception software triggers on
  purpose; FreeRTOS uses it to start the first task.

Both are attributed to a specific instruction token in MEM
(`trap_pending` travels to WB, and `backend_flush` performs the redirect and
kills younger tokens).  One important refinement: an async interrupt is
*not* attributed to a token whose side effects already committed in EXE
(CSR writes, `MRET`) — otherwise `mepc` would point at an instruction that
already executed.  For `mret` this was an actual livelock bug found by the
`my_mergesort_rtos` test; the story is written up in `docs/mem-subsys.md`.

## Q2. Which events are modeled as halts?

Halts are events *this simulation environment* treats as terminal: they
stop the run with an exit code instead of entering a handler.  From
`halt_kind_e` / `mem_stage.sv`:

| event | halt kind | exit code |
|---|---|---|
| EBREAK | `HALT_VOLUNTARY` | `a0[7:0]` (program's exit status) |
| illegal instruction | `HALT_ILLEGAL` | 130 |
| instruction fetch bus error | `HALT_BUS_ERROR_IF` | 131 |
| load / store bus error | `HALT_BUS_ERROR_LD/ST` | 132 / 133 |
| misaligned PC / load / store | `HALT_MISALIGN_*` | 134 |
| trap at `mtvec` base right after trap entry | `HALT_DOUBLE_TRAP` | 135 |

The dividing line is a *policy choice*, not an architectural one: a full
privileged implementation would trap on illegal instructions and misaligned
accesses too.  Halting instead (a) makes test failures loud and immediate —
`riscv-tests` end with ECALL/EBREAK conventions and a bad test dies with a
distinct exit code rather than vectoring into a handler loop, and (b) avoids
pretending to support trap causes the software stack here never handles.
`HALT_DOUBLE_TRAP` is the safety net for "trap handler itself traps
immediately" — without it, a broken `mtvec` would spin forever (this is
precisely how the timeout-style livelocks you *do* want to catch get
converted into a crisp exit code 135).

Halts also travel differently: they are not a redirect.  The token carries
`halt_observed` to WB, the commit packet reports it, and the testbench stops
the clock loop.  `pre_halt` beats both trap kinds in MEM's priority mux, so
a faulting instruction can never also take an interrupt.

## Q3. Why are stores gated in MEM?

```systemverilog
dmem_req_o.we = is_store_inst && !take_trap_o && !take_halt && !misaligned;
```

Because a store's write to memory is the one side effect in this pipeline
that happens *before* WB and cannot be undone.  Register writes are gated at
WB (`rf_we_o` checks `!trap_pending && !halt_observed`), CSR writes commit
in EXE only for tokens that survived kill — but a store, once on the bus, is
architectural state.  So MEM must prove, in the same cycle it launches the
request, that the store is really going to commit:

- not trapping (an interrupt taken on this token means it must *re-execute*
  after the handler — if the store had escaped, it would execute twice),
- not halting (a misaligned or faulting store must leave memory untouched),
- not killed (covered upstream: killed tokens are not `token_alive`).

The invariant is asserted at the bottom of `backend.sv`:

```systemverilog
assert (!(dmem_req_o.req_valid && dmem_req_o.we && mem_take_trap));
```

This is also why the lab roadmap lists "move stores into a committed store
buffer" as an extension: with a store buffer, MEM would only *record* the
store and the write would drain after WB commit, letting stores overlap
misses without the careful same-cycle gating.
