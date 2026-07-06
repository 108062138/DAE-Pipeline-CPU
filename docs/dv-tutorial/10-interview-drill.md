# Section 10: Interview Drill — Questions, Answers, UVM Mapping

## Translating this repo into UVM vocabulary

Most DV interviews assume UVM.  This repo's plain-SV benches implement the
same architecture, so learn the dictionary and you can discuss UVM
concretely even though the repo never types `uvm_`:

| UVM construct | what it is | this repo's equivalent |
|---|---|---|
| `uvm_sequence_item` | transaction object | `mem_req_t` / `mem_resp_t`, `commit_packet_t` |
| `uvm_sequence` | stimulus generator | the scenario `initial` block in `tb_mem_subsys.sv` |
| `uvm_driver` | transaction → pins | tasks `do_imem_read` / `do_dmem` |
| `uvm_monitor` | pins → transactions | the AW/AR counter block; commit-trace printer in `tb_top.sv` |
| `uvm_agent` | driver+monitor+sequencer per interface | the per-port task/counter groupings |
| `uvm_scoreboard` | expected vs. actual comparison | `check32`/`check_cnt`; the DPI golden model comparison |
| `uvm_env` / `uvm_test` | composition / configuration | `tb_mem_subsys` vs. `tb_top`+plusargs |
| config DB / factory | environment configuration & substitution | plusargs (`+ELF`/`+HEX`), Verilator `-G` parameters |
| objections / phases | end-of-test control | `done` flag + `+MAX_CYCLES` watchdog |

Things UVM adds that plain SV makes you do by hand — say these unprompted:
reuse via class inheritance and the factory (swap a driver without editing
the env), TLM ports decoupling monitor from scoreboard, sequence layering
and arbitration on one sequencer, phase-based reset/configure/run
structure, and a standard reporting/severity system.  UVM's *cost*:
boilerplate and abstraction weight — fine to say when asked "when would you
NOT use UVM?" (bring-up benches, formal-adjacent unit checks, this repo).

## Core question bank (with the strong answer's skeleton)

**Q: Verification vs. validation?**
Spec-compliance pre-silicon (simulation/formal/emulation) vs. real-world
behavior post-silicon (lab, in-system).  One sentence each, done.

**Q: What's in a verification plan?**
Feature list extracted from spec; per feature: stimulus, checker,
coverage point; plus configurations, error/negative cases, and
done-criteria.  Then: "I can walk you through the 9-row plan of a cache
testbench I know" (section 3's table).

**Q: Directed vs. constrained-random?**
Directed: hand-picked scenarios, fast to first bug, regression anchors.
CRV: constraints declare legal space, randomization explores it, coverage
steers it, seeds reproduce it.  Real flows run both; CRV needs a reference
model because you no longer know the expected values by hand.

**Q: What is a scoreboard?  (trap: this repo!)**
DV scoreboard: compares observed transactions against
predicted ones, typically fed by monitors through analysis ports.
Distinguish from a *CPU* scoreboard (issue-hazard tracker, e.g.
`src/scoreboard.sv` here) — naming the collision shows range.

**Q: Immediate vs. concurrent assertions?  `|->` vs `|=>`?**
Section 5's definitions, then *your* two examples: the store-during-trap
guard (immediate, from `backend.sv`) and AW-payload-stability (concurrent).

**Q: Code coverage 100% — ship it?**
No: checkers must have been on; functional coverage against the plan is
the real bar; exclusions need justification.  Then the two-hole story:
unreachable I$ write-back states (exclusion) vs. never-toggling error path
(missing test) — same metric, opposite actions.

**Q: How do you verify X?** (cache / arbiter / FIFO / async bridge)
Always the same skeleton: interfaces and contract → transaction types →
stimulus plan including negative space and back-pressure → checkers
(model or golden data) + protocol assertions → coverage including the
cross products → known holes.  For a FIFO specifically: fill/drain,
simultaneous push+pop at empty/full, pointer wrap (`fifo.sv`'s `ptr_next`),
flush mid-flight, data integrity via a mirror queue in the TB.
For an async FIFO add: CDC — gray-coded pointers, two-flop synchronizers,
and that *simulation can't prove CDC*; you need CDC lint + constrained
timing.  (This repo is single-clock; say so rather than bluff.)

**Q: Race conditions between TB and DUT?**
Sample with monitors on clock edges, drive on the opposite edge or through
clocking blocks/program blocks in UVM; never read a signal in the same
region you write it.  This repo's drivers drive on `negedge` for exactly
that hygiene.

**Q: Blocking vs. non-blocking assignment?**
`=` executes in order within a process (combinational), `<=` samples RHS
then updates (sequential state).  DV twist: TB code mixing them across
clocked processes creates order-of-evaluation heisenbugs — the classic
source of "fails once, passes on rerun" without randomization.

**Q: How would you find a bug that only appears when two events align?**
Timing sweeps: stimulus that shifts relative phase (the mergesort queue
ping-pong is a natural sweep), randomized delays/back-pressure, and
assertions so the *window itself* is checked rather than its downstream
symptom.  Then tell the mret story (section 9) as proof you've done it.

## Talking about this project (make it yours)

Prepare three 90-second stories, each with a number in it:

1. **The bug story** (section 9): interrupt-on-mret livelock; found by a
   stress test I designed to sweep tick/context-switch alignment; traced
   via commit-trace archaeology; one-line class fix; regression green.
2. **The checking story** (sections 3+7): structural checks (AXI traffic
   counters) caught an injected dirty-bit-loss mutation that all data
   checks passed; coverage triage separated a real hole (error path never
   toggles) from a justified exclusion (read-only I$'s WB states).
3. **The configuration story** (sections 4+8): swept 4 forwarding configs ×
   58 ISA tests, all green; commit traces bit-identical (59,098
   instructions) while cycles varied ~2% — architectural invariance as a
   cross-config checker.

Honesty calibration — say what the project *doesn't* have when relevant
(no UVM classes, no ISS lock-step, single clock domain, Verilator SVA
subset): interviewers probe claimed edges, and precise modesty reads as
seniority.

## Final drill protocol

For each section 1–9: close the file, and answer aloud —
(a) the section's core question in two sentences,
(b) its repo experiment and the number it produced,
(c) its interview-angle question cold.
Anything you can't do from memory, re-run the experiment — running it is
what moves it from "read" to "mine."
