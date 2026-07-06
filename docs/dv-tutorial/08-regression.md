# Section 8: Regression, Configurations, And Keeping It Green

## A regression is a machine for saying "still correct"

Individual tests prove behaviors once.  A **regression suite** re-proves
all of them after every change, mechanically.  Its value rests on
properties that have nothing to do with cleverness and everything to do
with hygiene:

- **Self-checking with machine-readable results** — every script here exits
  nonzero on failure because `$fatal` propagates to the simulator's exit
  code.  `set -euo pipefail` at the top of each script means a failure
  anywhere fails the run.  No human reads logs to decide pass/fail.
- **Bounded runtime** — every run has `+MAX_CYCLES` and the testbench
  `$fatal`s on expiry.  A regression that can hang is a regression nobody
  runs.  (And the timeout is itself a *liveness check* — it's what caught
  the mret livelock.)
- **Determinism** — same inputs, same result.  This bench is fully
  deterministic; in constrained-random environments the seed is part of the
  test identity: log it on failure, and rerunning with `+seed=X` must
  reproduce exactly.  "How do you debug a random failure?" — first answer:
  re-run the seed.
- **Fast tests run first.**  Unit test (~1 ms of sim) → ISA tests →
  programs → RTOS stress.  Cheap tests catching cheap bugs keep expensive
  tests for expensive bugs.

## This repo's suite as a worked example

| layer | script | proves | typical runtime |
|---|---|---|---|
| unit | `run-mem-subsys-test.sh` | cache/arbiter/DRAM in isolation | seconds |
| ISA | `run-riscv-tests.sh` (58 tests) | every instruction, traps, CSRs | ~1 min |
| integration | `run-my-fib.sh`, `run-my-fib-rtos.sh` | C runtime, kernel boot, queues | seconds |
| system stress | `run-freertos-demo.sh`, `run-my-mergesort-rtos.sh` | preemption, interrupts × timing sweep | seconds |

Two suite-design rules visible in it:

1. **Every fixed bug leaves a test behind.**  `run-my-mergesort-rtos.sh`
   exists *because* of the mret bug and now guards its class forever.  A
   fix without a regression test is a bug with a return ticket.
2. **Shared build, shared blast radius.**  All scripts compile the same
   `tb_top` file list — which is why adding the mem-subsys files required
   touching every script's `SV_FILES`, and why any RTL change triggers
   *all* layers, not just the "relevant" one.  (The mret fix was a
   one-line change to `mem_stage.sv`; the full suite re-ran because trap
   logic touches everything.)

## Configurations are a coverage axis

Parameters multiply the state space: this design has
`MEM_FORWARDING × WB_FORWARDING` (and cache geometry, queue depths...).  A
suite that only ever runs the default configuration has a permanent
stimulus hole in the *other* configurations' logic.

Real sweep from this repo (also in `my_lab_ans/lab3_ans.md`):

```sh
BUILD_DIR=obj_dir_dae_mf0_wf0 VERILATOR_PARAMS="-GMEM_FORWARDING=0 -GWB_FORWARDING=0" ./scripts/run-riscv-tests.sh
# ... all four combinations:
# 1/1, 1/0, 0/1, 0/0  ->  58/58 pass in every configuration
```

Plus the architectural cross-check: all four configs retire identical
commit traces (59,098 instructions on fib), differing only in cycles.
That's *configuration regression* + *trace invariance* in one experiment —
a compact story for "how do you verify a parameterized design?"
(Full N-dimensional sweeps explode combinatorially; real teams run the
default densely, corners of the config space nightly, and random configs
weekly.)

## Wiring it into CI

Everything above is scriptable, so the CI recipe is short: on every push,
build (`cmake --build build`), then run the layers in cost order, failing
fast.  What CI adds over a laptop: it runs *every* time (no "it's a tiny
change" exemptions — the mret fix was one line), on a clean machine (no
stale `obj_dir` masking build breaks), with an archived log for every
failure.  Nightly jobs get the expensive extras: configuration sweeps,
coverage collection (section 7), and long random runs.

Triage discipline when it goes red: reproduce (seed/config), bucket by
first-failure signature, bisect the commit range (`git bisect run
./scripts/run-mem-subsys-test.sh` automates it — exit codes again), then
apply section 9 to the guilty commit.

## Experiment

Prove your regression catches build-level mistakes, not just logic bugs:
delete `src/mem_subsys/cache.sv` from `SV_FILES` in
`scripts/run-riscv-tests.sh` and run it — instant elaboration failure
(missing module), nonzero exit.  Then try the subtler one: revert the mret
fix (section 1's experiment) and confirm the suite localizes it — unit test
green, ISA green, fib green, `mergesort-rtos` red.  The *pattern* of green
and red across layers is itself diagnostic information: memory subsystem
exonerated, single-instruction semantics exonerated, suspicion pinned on
interrupt × pipeline interaction.  That reading-the-matrix skill is
section 9's opening move.

## Interview angle

- "What makes a good regression test?" → self-checking, bounded, deterministic
  (or seed-reproducible), fast, and guarding a specific behavior or past bug.
- "A random test fails once and passes on rerun — what now?" → the rerun
  used a new seed; recover the failing seed from the log, rerun it exactly,
  then debug.  If the seed doesn't reproduce it, suspect
  order-of-evaluation races in the *testbench*.
- "How do you verify a design with many parameters?" → treat configuration
  as a coverage axis; sweep the cheap dimensions (shown above), sample the
  expensive ones, and check architectural invariants across configs.
