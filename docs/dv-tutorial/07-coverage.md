# Section 7: Coverage — Measuring What You Actually Tested

## Coverage answers the activation question

Sections 2–6 built observation (checkers, models, assertions).  Coverage
measures the other leg of the triad: **did stimulus ever reach the states
where bugs could hide?**  A perfect checker attached to unreached logic
verifies nothing, and without coverage you cannot distinguish "no bugs"
from "no stimulus."

Two fundamentally different kinds:

- **Code coverage** — mechanical, tool-generated: were lines executed,
  did signals toggle, were FSM states/arcs visited, did branches go both
  ways?  Necessary, cheap, and *insufficient*: it measures the
  implementation, not the spec.
- **Functional coverage** — human-declared: did the *scenarios from the
  verification plan* occur?  Written as covergroups/coverpoints (or
  `cover property`), it measures the spec.  Code coverage can hit 100%
  while "dirty eviction during concurrent I$ miss" never happened once.

## A real code-coverage run on this repo

```sh
BUILD_DIR=obj_dir_mem_subsys_cov VERILATOR_PARAMS="--coverage" \
  ./scripts/run-mem-subsys-test.sh
verilator_coverage coverage.dat --annotate /tmp/cov_annot
```

Actual results for the mem-subsys unit test:

```text
line      : 89.7%  (  61/  68)
toggle    : 22.1%  (1170/5290)
fsm_state : 87.0%  (  20/  23)
fsm_arc   : 100.0% (   4/   4)
```

Now the important part — *reading* it.  The annotated `cache.sv` shows the
three unvisited FSM states:

```text
%000000  [fsm_state ...u_icache.state_q::WB_ADDR] *** UNCOVERED ***
%000000  [fsm_state ...u_icache.state_q::WB_DATA] *** UNCOVERED ***
%000000  [fsm_state ...u_icache.state_q::WB_RESP] *** UNCOVERED ***
```

and a never-toggling signal: `err_q` (both caches).  Two holes, two
*completely different verdicts*:

1. **I-cache write-back states: unreachable by design.**  The I$ is
   instantiated with `WRITE_BACK=0`; no stimulus can ever reach WB_* in it.
   Correct action: a documented **coverage exclusion** ("I$ is read-only by
   parameter; WB states unreachable"), not a new test.  Chasing 100% here
   would mean *breaking the design to satisfy the metric*.
2. **`err_q` never toggles: a genuine stimulus hole.**  The error-response
   path (`rresp[1]`/`bresp[1]` accumulation into `resp.error`) is real,
   reachable functionality that no test exercises — the same hole section 3
   listed in "negative space" from first principles.  Coverage found it
   mechanically.  Correct action: error-injection stimulus.

That pair is the entire discipline of **coverage closure** in miniature:
every hole is triaged into {new test, exclusion with written justification,
dead code to delete} — and the triage record is reviewable evidence.

(Also note toggle coverage's character: 22.1% sounds alarming but includes
every bit of every 32-bit bus — address bits that never vary in a 64KiB
model, QoS wires tied constant.  Toggle is a hole *detector*, not a quality
*score*.  Never quote a toggle percentage without reading the holes.)

## Functional coverage: what it would look like here

The cache's scenario space is a cross product; a covergroup states it
directly:

```systemverilog
covergroup cg_dcache_op @(posedge clk_i);
    cp_rw:     coverpoint req_q.we      { bins rd = {0}; bins wr = {1}; }
    cp_hit:    coverpoint hit           { bins hit = {1}; bins miss = {0}; }
    cp_victim: coverpoint (valid_q[req_idx] && dirty_q[req_idx])
                                        { bins clean = {0}; bins dirty = {1}; }
    x_op: cross cp_rw, cp_hit, cp_victim;   // 8 scenario bins
endgroup
```

Score the current directed suite against those 8 bins and you find 7 hit
and one hole: **write miss onto a dirty victim** (test 4 allocates onto a
clean line; test 7's dirty eviction is a *read* miss).  A byte-enable
coverpoint (`be` bins: 0001/0010/0100/1000/0011/1100/1111) would similarly
show only three of seven patterns exercised.  This is how functional
coverage drives test writing: the covergroup is the verification plan in
executable form, and its holes are next week's test list.

(Verilator's covergroup support is limited; in this repo you'd express the
same points as `cover property` statements or hand counters — the concept,
not the syntax, is what interviews test.)

## Coverage in the loop

The closure loop that teams actually run: write plan → implement tests →
run with coverage → triage holes → add tests/exclusions → repeat until the
plan's coverpoints are 100% *with all checkers on*.  Two traps to name:

- **Coverage without checking**: hitting a state proves activation, not
  correctness.  A run with checkers disabled contributes nothing (some
  teams literally invalidate coverage from failing/checker-off runs).
- **Metric gaming**: excluding holes without justification, or writing
  stimulus that touches states without meaningful data.  The written
  triage record is the defense.

## Mutation testing: coverage for your checkers

Coverage asks "did stimulus reach the logic?"  Mutation testing asks the
dual: **"if this logic were wrong, would any check notice?"**  Inject a
plausible bug, run the suite, demand a failure.  Real run from this repo —
the injected bug: write hits no longer set the dirty bit
(`dirty_q[req_idx] <= 1'b0;` in `cache.sv`):

```text
PASS dcache read hit @0x100 (deadbeef)        <- data checks still pass!
PASS byte-enable merge @0x101 (dead55ef)
PASS conflict read @0x1100 (fresh dram)
%Fatal: FAIL dirty eviction issues writeback: got 0 expected 1
```

Instructive on two axes: the data-only checks sailed past the bug (the
line still held the written data — the loss only matters at eviction), and
the *structural* check (AW counter, section 3) caught it.  A mutation that
survives the whole suite is a checking hole, exactly as an uncovered state
is a stimulus hole.

## Interview angle

- "Code vs. functional coverage?" → implementation-derived vs.
  plan-declared; give the `err_q` (code found it) and write-miss-dirty
  (only functional would find it) examples.
- "You're at 100% coverage — are you done?" → only if: checkers were on,
  functional (not just code) coverage is closed against a reviewed plan,
  and exclusions are justified.  Then still say "coverage bounds tested
  behavior; it is evidence, not proof."
- "What do you do with an uncovered state?" → triage: test hole vs.
  unreachable-by-design vs. dead code — with the I$ WB-state story as your
  worked example.
