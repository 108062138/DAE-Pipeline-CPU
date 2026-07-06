# Section 5: Assertions — Immediate And Concurrent (SVA)

## What assertions add that tests cannot

Tests check behavior at chosen observation points at chosen times.
Assertions check **invariants continuously, everywhere, under every test
that runs**.  They are the cheapest leverage in DV: write once, and every
future test — directed, random, or a workload someone runs five years from
now — is silently strengthened.  They also localize failures: a test fails
at the *symptom*; an assertion fails at the *first violation*, usually
within a cycle of the root cause.

## Immediate assertions: the two already in this repo

`src/backend.sv` ends with:

```systemverilog
always_ff @(posedge clk_i) begin
    if (!rst_i) begin
        assert (!(dmem_req_o.req_valid && dmem_req_o.we && mem_take_trap));
        assert (!(ir_valid_i && backend_flush));
    end
end
```

Immediate assertions are procedural: evaluated like a statement, here once
per clock.  Read what these two encode — both are *design intent that no
functional test directly states*:

1. A store request must never launch in a cycle where the token is
   trapping.  This is the "stores are irreversible" invariant from the halt
   model; a violation means memory corruption that a data check might not
   notice for a million cycles.
2. The frontend must never present an instruction in the same cycle the
   backend flushes — an issue/kill race guard.

That is the art of assertion writing: state the property whose violation is
*distant* from its symptom.

## Concurrent assertions (SVA): properties over time

Concurrent assertions sample on a clock and can express sequences:

```systemverilog
// AXI: once valid is asserted, it must hold until ready (no retraction)
property p_awvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    axi.awvalid && !axi.awready |=> axi.awvalid;
endproperty
assert property (p_awvalid_stable);

// AXI: the payload must not change while waiting for ready
property p_awaddr_stable;
    @(posedge clk) disable iff (!rst_n)
    axi.awvalid && !axi.awready |=> $stable(axi.awaddr) && $stable(axi.awlen);
endproperty
assert property (p_awaddr_stable);

// Cache FSM: a fill burst delivers exactly LINE_WORDS beats
// (rlast must be seen on beat LINE_WORDS-1 and only there)
property p_rlast_position;
    @(posedge clk) disable iff (!rst_n)
    (axi.rvalid && axi.rready) |-> (axi.rlast == (beat_q == LINE_WORDS-1));
endproperty
```

Syntax survival kit for interviews:

- `|->` same-cycle implication; `|=>` next-cycle implication.
- `##n` delay n cycles; `##[1:$]` eventually (unbounded).
- `$stable(x)`, `$past(x)`, `$rose(x)`, `$fell(x)` — sampled-value functions.
- `disable iff (cond)` — abandon the attempt during reset/flush.
- `assert property` (must hold) vs. `cover property` (want to see it
  happen — coverage's cousin, section 7) vs. `assume property` (constraint
  for formal).

## Where to put assertions

- **Inline in RTL** (like `backend.sv`): best for micro-invariants using
  internal signals ("`state_q == WB_DATA` implies the line was dirty").
  Designer-owned, travels with the code.
- **In the interface**: `axi_if` is the natural home for AXI handshake
  rules — every master and slave connected through it gets checked for
  free.  This is the highest-value location in this repo.
- **Bound in from outside** (`bind cache cache_sva u_sva(.*)`): DV-owned
  checkers attached without touching design files — how commercial VIP
  protocol monitors attach.  Keeps the adversarial code independent of the
  code it distrusts (section 1).

Practical note: Verilator supports immediate assertions and a useful subset
of concurrent SVA (simple implications like the above compile and fire with
`--assert`; unbounded/complex sequences may not) — good enough for
everything in this section.  Commercial simulators support the full
language; know that the *portable subset* is what most teams actually write.

## The assertion this repo was missing

The mret bug (sections 1, 9) had a perfect assertion shape, stated from the
RISC-V spec: *a taken interrupt must never write `mepc` with the address of
an instruction whose side effects already executed*.  A practical
approximation at trap entry:

```systemverilog
// In backend.sv: trap entry must not name a CSR/MRET token as "interrupted"
assert property (@(posedge clk_i) disable iff (rst_i)
    (backend_flush && mem_trap_cause[31]) |->
    (mem_q.ir.fu_type != FU_CSR && mem_q.ir.sys_kind != SYS_MRET));
```

Had this existed, the bug would have fired the assertion at the guilty
cycle — instead of 300k cycles later as a timeout, followed by a day of
trace archaeology.  Post-fix, this assertion is also the *regression* for
the fix, stronger than the mergesort test because it checks the property
under every workload forever.  Writing the assertion you wish you'd had is
the best post-mortem habit in DV.

## Experiment

Add `p_awvalid_stable` and `p_awaddr_stable` inside `axi_if`
(`src/AXI/AXI_interface.sv`), guarded with `` `ifndef SYNTHESIS ``, build
with `VERILATOR_PARAMS="--assert"` and run the unit test — they should pass.
Then make the cache retract `awvalid` after one cycle (change the
`state_q == WB_ADDR` term to also require `beat_q == 0` and force a beat
increment — any hack that deasserts early) and watch the assertion name the
exact cycle.  Revert afterwards.

## Interview angle

- "Immediate vs. concurrent assertion?" → procedural single-cycle check vs.
  clocked temporal property; give one real example of each (you now have
  both, from this repo).
- "`|->` vs `|=>`?" → overlapping (same cycle) vs. non-overlapping (next
  cycle) implication.
- "Where would you add assertions to design X?" → handshake rules at every
  interface, one-hot/state invariants inside FSMs, and irreversible-action
  guards (the store-gating assert is a model answer).
- "How do assertions help debug?" → they move detection from symptom-time
  to violation-time; retell the mret story in one sentence.
