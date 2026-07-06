# Lab 4 Answers: EXE And Branch Redirect

Files studied: `src/alu.sv`, `src/branch_unit.sv`, `src/exe_stage.sv`.

## Q1. Why is prediction always not-taken?

Because it is the only prediction that costs literally nothing to make:

- The frontend already fetches `pc + 4` by default (`if_stage.sv` increments
  after every accepted request), so "predict not-taken" requires no
  predictor storage, no lookup, no training, and no extra pipeline fields —
  the prediction *is* the fetch policy.
- The recovery mechanism (epoch bump + redirect + younger-token kill) must
  exist anyway for `mret` and traps.  Reusing it for branches means taken
  branches are just one more caller of infrastructure the core cannot avoid
  having.
- Pedagogically it isolates concerns: Lab 4 is about making redirect
  *correct*.  Making it *fast* (a BTB/bimodal predictor) is deliberately
  deferred to Lab 8, where it becomes an incremental change: predict in IF,
  and let EXE redirect only on actual mispredicts instead of on every taken
  branch.

The cost is visible and honest: every taken branch pays the full
IF→ID→queue→IS→EXE refill latency.

## Q2. Why does a taken branch imply redirect?

Look at `branch_unit.sv`:

```systemverilog
mispredict = taken;
```

"Mispredict" is defined relative to the prediction.  Since the frontend
always predicted not-taken (it fetched and queued the fall-through path),
*any* taken branch means the instructions behind it in the pipe are wrong.
So EXE must:

1. redirect fetch to the computed target
   (`redirect_pc_o` — `pc + imm`, or `(rs1 + imm) & ~1` for JALR), and
2. kill everything younger (the `kill_event` in `backend.sv`, built from the
   branch's own epoch/seq_id so exactly the younger tokens die).

Note JAL/JALR are unconditionally `taken`, so *every* jump redirects — the
price of having no BTB: even a statically known target like JAL is fetched
as fall-through first.

A subtlety: a *not-taken* branch never redirects, so the correct-path
instructions already fetched behind it survive — that is the half of the
prediction that wins.

## Q3. Why is EXE-to-IS forwarding not implemented?

Three reasons, in increasing order of importance:

1. **The value may not exist at all.**  If the EXE-row instruction is a
   load, its result is produced by MEM one or two-plus cycles later
   (arbitrarily later on the cache path).  An EXE→IS bypass would still need
   the stall path for loads, so it removes only a subset of stalls while
   adding a full network.
2. **Timing.**  Issue happens in the same cycle as EXE computes.  Forwarding
   EXE's output into the issuing instruction's operand latch chains
   *this* cycle's ALU behind the issue decision and register read — and the
   dependent instruction executes its own ALU next cycle.  The wire is a
   same-cycle path: issue-mux → operand → (next cycle) ALU is fine, but the
   source is `alu_result`, which is itself at the end of a full
   decode-mux + ALU path.  In other words: it is the classic
   "back-to-back ALU" critical path, the exact path that limits fmax in real
   cores.
3. **The scoreboard structure makes waiting cheap and clean.**  A
   distance-1 dependency stalls exactly one cycle; the producer moves to the
   MEM row where `mem_result_bus` forwarding already exists (for non-loads
   `exe_rd_ready` marks the row ready as it shifts).  So the added
   complexity would buy back only that single bubble, at the cost of the
   worst timing path in the design.

The trade is: accept CPI loss on dependent pairs, keep the cycle time and
the issue logic simple.  (The measured cost of the *existing* forwarding
paths in Lab 3 — ~2% — suggests EXE→IS forwarding would similarly be a
small-single-digit-percent win on this core, and not worth its wires yet.)
