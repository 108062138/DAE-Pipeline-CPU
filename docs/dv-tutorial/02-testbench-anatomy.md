# Section 2: Testbench Anatomy — Driver, Monitor, Checker

## The canonical shape

Every simulation testbench, from a 50-line directed bench to a full UVM
environment, decomposes into the same roles:

```text
 +-----------+   transactions   +--------+   pins    +-----+
 | sequencer | ---------------> | driver | --------> |     |
 | (what to  |                  | (how to|           | DUT |
 |  send)    |                  |  wiggle|           |     |
 +-----------+                  |  pins) |           +--+--+
                                +--------+              | pins
                                                        v
                    +------------+   observed    +---------+
      expected      | scoreboard | <------------ | monitor |
      behavior ---> | / checker  |  transactions +---------+
      (ref model,   +------------+
       golden data)       |
                          v
                   pass / $fatal
```

The separation matters because each role has a different reason to change:
stimulus strategy (sequencer), pin protocol (driver/monitor), and
correctness definition (checker) evolve independently.  Interviews often ask
you to "draw a testbench for block X" — this diagram, with roles explained,
is the expected answer regardless of whether the house style is UVM.

## Finding every role in `tb/tb_mem_subsys.sv`

The repo's unit bench is plain SystemVerilog, ~190 lines, but every role is
present.  Open it side by side:

| role | where in `tb_mem_subsys.sv` |
|---|---|
| DUT | `mem_subsys` + `axi_dram_model` (the memory side is part of the test fixture) |
| sequencer | the main `initial` block — the ordered list of scenarios |
| driver | tasks `do_imem_read()` / `do_dmem()` — own the `mem_req_t` handshake details (drive on `negedge`, wait for `req_ready`, deassert, wait for `resp_valid`) |
| monitor | the `always @(posedge clk)` block counting `awvalid && awready` / `arvalid && arready` at the DRAM boundary |
| checker | `check32()` (data correctness) and `check_cnt()` (traffic correctness), both ending in `$fatal` on mismatch |
| watchdog | the second `initial` block: 20,000 cycles then `$fatal("timeout")` |

Points worth internalizing (and quoting):

- **Drivers encapsulate the protocol so tests read as intent.**  The
  scenario list says `do_dmem(write, 0x100, ...)`; only the driver knows the
  handshake dance.  When the protocol changes, tests don't.
- **The monitor watches a *different* interface than the driver drives.**
  Stimulus enters on the CPU-side single-beat port; observation happens at
  the AXI boundary.  Checking at a different abstraction level than you
  drive is what catches "right data, wrong mechanism" bugs — e.g., a cache
  that misses every access returns correct data but fails the AR count.
- **Passive monitors only sample.**  The counter block reads handshake
  signals; it never drives.  In UVM this is enforced by class structure;
  in plain SV it's discipline.

## The system bench: `tb/tb_top.sv`

The second testbench shows a different pattern: the DUT is the whole CPU,
stimulus is a *program* (ELF), and checking is done by a **reference model**
— the snake_soc C model behind DPI serves memory/devices, and correctness is
judged end-to-end (the program itself computes pass/fail, plus a commit
trace for debugging).  Section 4 covers this style.  Note also its two
response paths (DPI vs. cache+AXI): a testbench can host multiple
*environments* around one DUT, selected by plusargs.

## A warning about the word "scoreboard"

This repo contains `src/scoreboard.sv` — a *hazard-tracking RTL structure*
inside the CPU, the classic CDC-6600 usage.  In DV, "scoreboard" means the
*testbench component that compares expected vs. actual transactions*.  Same
word, unrelated things.  Saying this unprompted in an interview signals you
know both worlds; confusing them signals the opposite.

## Directed, constrained-random, formal

Three stimulus philosophies, all examinable:

- **Directed** (this repo): you enumerate scenarios by hand.  Best
  effort-to-first-bug ratio, great for bring-up and for locking in
  regressions; weak against the corners you didn't think of.
- **Constrained-random (CRV)**: declare legal stimulus as constraints,
  randomize, let coverage tell you what's been hit.  Finds the corners you
  didn't think of, at the cost of a reference model that must predict *any*
  legal stimulus, plus seed management (section 8).
- **Formal**: no stimulus at all — the tool proves assertions over all
  reachable states, exhaustively but only for properties you can state and
  blocks small enough to converge.

A strong interview answer sequences them: directed for bring-up and
known corners, CRV for breadth on the integrated block, formal for
protocol/arbitration kernels (the `axi_arbiter` here is an ideal formal
target: small, and "grant is held for a full burst" is a crisp property).

## Experiment

Break the driver's discipline and watch why it exists: in `do_dmem()`,
remove the `while (!dmem_ready) @(negedge clk);` line and run
`./scripts/run-mem-subsys-test.sh`.  Requests issued while the cache FSM is
busy are silently lost, and the bench hangs until the watchdog fires —
demonstrating both (a) drivers must respect flow control, and (b) every
testbench needs a watchdog because *hangs are a failure mode of testbenches,
not just DUTs*.  Revert with `git checkout tb/tb_mem_subsys.sv`.

## Interview angle

- "Draw a testbench for a FIFO / cache / arbiter" → the diagram above, then
  populate each role concretely.
- "What's the difference between a monitor and a driver?" → direction and
  activeness: driver converts transactions to pin wiggles (active), monitor
  converts pin wiggles back to transactions (passive, never drives).
- "Why separate checker from stimulus?" → independence (section 1) and
  reuse: the same checker must work under directed *and* random stimulus.
