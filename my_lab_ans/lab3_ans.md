# Lab 3 Answers: Register File And Scoreboard

Files studied: `src/regfile.sv`, `src/scoreboard.sv`, IS logic in
`src/backend.sv`.

## How issue decides (the rules being measured)

The scoreboard keeps one row per backend stage (EXE/MEM/WB).  For each source
register of the issue candidate, the *oldest matching producer wins*:

| producer location | behavior |
|---|---|
| EXE row | always stall (result does not exist yet) |
| MEM row | forward `mem_result_bus` if `MEM_FORWARDING && rd_ready`, else stall |
| WB row  | forward `wb_result_bus` if `WB_FORWARDING && rd_ready`, else stall |
| none    | read the register file |

Two details worth noticing:

- A dependency on the instruction *immediately ahead* (producer in EXE)
  stalls no matter what the parameters say.  There is no EXE→IS forwarding
  (see Lab 4 Q3), so the best case for a back-to-back dependent pair is a
  one-cycle bubble.  Forwarding parameters only affect dependence distances
  2 and 3.
- `rd_ready` matters for loads: a load's result is not ready while it sits
  in the MEM row waiting for the D-memory response
  (`mem_rd_ready = req_sent_q && resp_valid` in `mem_stage.sv`), so even
  with MEM forwarding enabled a load-use pair waits for the data to actually
  arrive.

## Experiment: run all four forwarding configurations

Builds (each also passes the full ISA regression, 58/58 — forwarding is a
pure performance feature, never a correctness feature):

```sh
BUILD_DIR=obj_dir_dae_mf0_wf0 VERILATOR_PARAMS="-GMEM_FORWARDING=0 -GWB_FORWARDING=0" ./scripts/run-riscv-tests.sh
BUILD_DIR=obj_dir_dae_mf1_wf0 VERILATOR_PARAMS="-GMEM_FORWARDING=1 -GWB_FORWARDING=0" ./scripts/run-riscv-tests.sh
BUILD_DIR=obj_dir_dae_mf0_wf1 VERILATOR_PARAMS="-GMEM_FORWARDING=0 -GWB_FORWARDING=1" ./scripts/run-riscv-tests.sh
```

Measured on `my_fib` (`build/my_fib/my_fib`, 59,098 committed instructions —
identical in all configs, as architecture demands; cycle counts found by
bisecting `+MAX_CYCLES` to the smallest value that reaches halt):

| config (MEM fwd / WB fwd) | cycles | vs. both on | IPC |
|---|---|---|---|
| 1 / 1 (default) | 191,249 | — | 0.309 |
| 0 / 1 | 191,517 | +268 (+0.14%) | 0.309 |
| 1 / 0 | 193,584 | +2,335 (+1.2%) | 0.305 |
| 0 / 0 | 195,182 | +3,933 (+2.1%) | 0.303 |

## What the numbers teach

1. **Forwarding is worth ~2% total on this core.**  Baseline IPC is ≈0.31,
   dominated by structural costs that forwarding cannot touch: single-beat,
   single-outstanding instruction fetch (a fetch takes ≥2 cycles on the DPI
   path), the mandatory EXE-row stall for distance-1 dependencies, and MEM
   stalls for every load/store round trip.  When the base CPI is ≈3.2,
   shaving occasional 1-cycle hazard bubbles moves the needle very little.
   Lesson: forwarding networks pay off in proportion to how good the rest of
   the pipeline already is.
2. **The WB path matters more than the MEM path here** (+2,335 vs. +268
   cycles when disabled).  Two effects line up: (a) loads are only
   `rd_ready` once their response arrives, so many MEM-row matches cannot
   forward yet anyway, and the consumer ends up catching the producer in the
   WB row a cycle later; (b) MEM stalls insert WB bubbles
   (`wb_q <= '0` on stall in `backend.sv`), stretching how long producers
   stay visible in MEM/WB rows and pushing dependents toward the WB
   window.  Disabling WB forwarding converts all of those into stalls until
   the value is safely in the register file.
3. **Configs compose almost additively** (268 + 2,335 ≈ 2,603 vs. measured
   3,933 for both off — the extra 1,330 cycles are dependents that would
   have forwarded from MEM but, with MEM off, then *also* find WB
   forwarding unavailable and pay a second stall).  Hazard populations
   interact; you cannot always sum microarchitecture deltas.
