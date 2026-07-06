# Section 4: Reference Models And Trace Comparison

## Why checks alone stop scaling

Directed checks encode expected values you computed by hand.  That works for
nine cache scenarios; it cannot work for "run FreeRTOS for 400k cycles."
At system scale the expected behavior must be *computed*, by an independent
implementation of the same spec: a **reference model** (golden model).

The comparison styles, in increasing coupling:

1. **End-to-end self-checking program**: the workload itself computes
   pass/fail.  Cheapest, catches only bugs that corrupt the final answer.
2. **Trace comparison (post-hoc)**: DUT emits a transaction log; a model
   (or another DUT configuration) emits the same; diff offline.
3. **Lock-step co-simulation**: model advances with the DUT and every
   commit is compared on the fly; divergence is flagged at the *first*
   wrong instruction, not the final answer.

## How this repo uses each style

**Style 1 — self-checking programs.**  The riscv-tests ISA suite is the
canonical example: each test computes a signature and ends in a
pass/fail convention (ECALL/EBREAK with a code), which `mem_stage`'s halt
model turns into an exit code the script checks.  `my_fib`, and the
FreeRTOS tests with their `PASS`/`FAIL` prints plus `halt(0/1)`, are the
same pattern.  Strength: zero testbench modeling effort — the RISC-V
authors did it.  Weakness: a bug that doesn't perturb the signature
(performance bugs, transient wrong-path effects) is invisible.

**Style 2 — trace comparison.**  `wb_stage` emits a `commit_packet_t` per
retired instruction (PC, rd, value, store address/data/strobes, trap
info) and `tb_top` prints it.  Because the packet is *architectural*, it
must be identical across microarchitectural configurations.  Real
experiment from this repo: all four forwarding configurations
(`MEM_FORWARDING`/`WB_FORWARDING` swept) retire **exactly 59,098
instructions with identical traces** on `my_fib` — cycle counts differ
(191,249 to 195,182), the instruction stream does not.  Diffing commit
traces between a known-good and a suspect build is the fastest CPU debug
tool that exists (section 9 uses it heavily).

**Style 3 — the DPI reference environment.**  In `+ELF` mode, the
snake_soc C model behind DPI (`dpi/snake_soc_dpi.c`) serves every fetch
and data access, models the devices (UART, CLINT), and drives interrupt
lines.  It is a trusted software implementation of the *memory system
and platform* — so any misbehavior observed while running on it is
attributable to the CPU RTL.  Conversely, the `+HEX` path swaps in the
RTL memory subsystem against the same CPU: two environments, one DUT,
which is itself a comparison lever ("does the bug follow the CPU or the
memory system?").

A full lock-step CPU checker (an ISS like Spike compared per commit) is the
industry-standard next step this repo doesn't have yet — worth naming as
future work; the `commit_packet_t` port is exactly the hook it would need.

## Rules for reference models

- **Model at the highest abstraction that still catches the bug class.**
  The snake_soc model is untimed C — perfect for functional checking,
  useless for verifying stall behavior.  That's a feature: timing bugs are
  section 5/6's job (assertions, protocol checks), not the model's.
- **Independence is the whole point.**  The C DRAM model and the RTL cache
  path were written from the same spec but share no code — when
  `tb/smoke.hex` runs identically on both paths, that agreement means
  something.  A "model" generated from the RTL would only prove the RTL
  equals itself.
- **The model is also wrong sometimes.**  When trace and RTL diverge, you
  have *two* suspects (three, counting the spec).  The divergence point
  plus the spec settles it.
- **Watch for modeling the bug.**  If a model quirk makes a DUT bug pass
  (e.g., a model that also ignores byte strobes), comparison proves
  nothing.  This is why protocol assertions run *alongside* model
  comparison, not instead of it.

## Experiment: trace comparison by hand

Prove the architectural-invariance property yourself:

```sh
obj_dir_dae/Vtb_top          +ELF=build/my_fib/my_fib +MAX_CYCLES=200000 > /tmp/t_base.log
obj_dir_dae_mf0_wf0/Vtb_top  +ELF=build/my_fib/my_fib +MAX_CYCLES=200000 > /tmp/t_nofwd.log
diff <(grep ^commit /tmp/t_base.log) <(grep ^commit /tmp/t_nofwd.log) && echo IDENTICAL
```

(Build the no-forwarding simulator as in `my_lab_ans/lab3_ans.md` if you
haven't.)  Then break something microarchitectural-but-visible — e.g.,
disable the scoreboard's EXE-row hazard check — and watch the diff pinpoint
the first divergent commit, which is dramatically more actionable than
"FAIL" at the end of a run.

## Interview angle

- "How do you verify a CPU?" → layered answer: ISA tests (style 1) +
  commit-trace/ISS comparison (styles 2/3) + protocol assertions on the
  memory interfaces + OS-level stress.  This repo demonstrates every layer
  except the ISS, and you can say which layer caught which real bug.
- "What if the reference model disagrees with the DUT?" → find the first
  divergence, consult the spec, be prepared for the model to lose.
- "Golden model vs. scoreboard?" → the model *predicts* expected
  transactions; the scoreboard *compares* predicted vs. observed.  They're
  two halves of style 3.
