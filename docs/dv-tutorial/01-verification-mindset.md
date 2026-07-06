# Section 1: The Verification Mindset

## Design proves it can work; verification proves it can't fail

A designer's job is constructive: make the intended behavior exist.  A
verifier's job is adversarial: assume the design is broken and hunt for the
evidence.  These are genuinely different mental stances, and interviews test
for the second one.  When a DV interviewer shows you a block, the expected
first response is not "how does it work" but "what could be wrong with it,
and how would I catch it?"

The working definition to carry around:

> Verification is the process of building an independent, redundant
> prediction of design behavior, and mechanically comparing the design
> against it under stimulus you chose to be hostile.

Every word earns its place: *independent* (derived from the spec, not from
the RTL — a checker copied from the design's own logic verifies nothing),
*redundant* (two ways of computing the same answer), *mechanical* (a human
eyeballing waveforms does not scale and does not rerun at 2am), *hostile*
(bugs live in corners; friendly stimulus visits the middle).

## The three questions

For a bug to be found in simulation, three things must all happen.  This
triad is the skeleton of all DV methodology, and every later section of this
tutorial is one of these questions elaborated:

1. **Activation** — does some stimulus put the design into the buggy state?
   (Sections 3, 8: tests, configurations. Section 7: coverage measures this.)
2. **Propagation & observation** — does the bug's effect reach a point where
   something is watching?  (Sections 2, 4, 5, 6: monitors, reference models,
   assertions.)
3. **Detection is loud** — does the mismatch stop the run with a clear
   message, rather than scrolling past in a log?  (Self-checking tests,
   `$fatal`, exit codes, watchdogs.)

A bug that is activated but not observed passes silently.  A checker that
would catch the bug but never receives activating stimulus also passes
silently.  Coverage without checkers is as useless as checkers without
coverage.

## Case study: why "it passes all the tests" means little

This repo's CPU passed four whole test suites — 58 ISA tests, two bare-metal
programs, and a FreeRTOS demo with live timer interrupts — while containing a
fatal bug: an interrupt arriving in the exact cycle an `mret` sat in the MEM
stage would corrupt `mepc` and livelock the system
(full story in `docs/mem-subsys.md`, and section 9 walks the debug).

Run the pre-fix experience yourself by reverting the fix temporarily:

```sh
git stash list   # make sure your tree is clean first
# in src/mem_stage.sv, remove the "(mem_i.ir.fu_type != FU_CSR) &&
# (mem_i.ir.sys_kind != SYS_MRET)" terms from async_trap, then:
./scripts/run-freertos-demo.sh        # still PASSES - insufficient stimulus
./scripts/run-my-mergesort-rtos.sh    # hangs -> timeout assertion fires
git checkout src/mem_stage.sv
```

Analysis in the triad's terms:

- **Activation** required a timer tick to land within a 1-cycle window
  around an `mret` commit.  `freertos_demo`'s two polite tasks never created
  that alignment; the mergesort test's queue ping-pong sweeps context-switch
  timing until it does.
- **Observation** was indirect: no assertion watched `mepc`.  The bug was
  observed only as its distant symptom — no forward progress.
- **Detection** worked only because the testbench treats timeout as failure
  (`$fatal` on cycle limit).  A testbench that "ran 400k cycles and exited"
  would have shipped this bug.

Each of those three sentences is a lesson you can quote in an interview.

## Where predictions come from: the spec stack

You can only check against something you trust more than the RTL.  This repo
has a full spec stack, and knowing which level answers which question is a
skill interviews probe:

| level | document | example question it settles |
|---|---|---|
| ISA / architecture | RISC-V spec | may an interrupt set `mepc` to an `mret`'s own PC? (no) |
| implementation spec | `spec.md` | which events halt vs. trap in *this* core? |
| protocol | AXI4 spec (ARM IHI 0022) | may `awaddr` change while `awvalid` waits? (no) |
| block contract | comment headers, `docs/mem-subsys.md` | I-cache is read-only; D-cache is write-back |

When the RTL and the spec disagree, the spec wins until a human decides
otherwise — sometimes the spec is wrong, but that decision gets made
explicitly, not by silently trusting the code.

## Test bugs are half your bugs

Expect to spend as much time debugging your testbench as the design.  A
failing check has three possible causes — design bug, test bug, spec
ambiguity — and a verifier's credibility rests on identifying which, with
evidence, before filing anything.  Section 9's method applies to all three.

## Interview angle

- "What is the difference between verification and validation?"
  Verification: does the design match the spec (pre-silicon, this whole
  tutorial).  Validation: does the product work in the real world
  (post-silicon, in-system).
- "A block passes all its tests. Is it verified?"  No — passing tests only
  bounds the *tested* behavior.  Answer with the activation/observation/
  detection triad and, ideally, a story like the one above.
- "What makes stimulus good?"  It reaches states the designer didn't
  consciously construct: boundaries, concurrent events, timing alignments,
  back-pressure, and the cross-products of all of those.
