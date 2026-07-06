# DV Tutorial: Learning Design Verification On This Repo

A ten-section course on digital verification, taught entirely with the
verification artifacts that already exist in this repository.  Every section
has runnable experiments — the numbers quoted in the text are real outputs
from this codebase, and each section ends with an **Interview angle** telling
you how the material maps to common DV interview questions.

The repo is a good DV classroom because it contains one of everything:

- a directed, self-checking unit testbench (`tb/tb_mem_subsys.sv`),
- a system testbench with a golden reference model (`tb/tb_top.sv` + DPI),
- a protocol (AXI4) with a spec to check against,
- a regression suite (`scripts/`),
- immediate assertions in the RTL (`src/backend.sv`),
- and a genuine, documented CPU bug found by a test
  (the interrupt-on-`mret` livelock — see `docs/mem-subsys.md`).

## Sections

| # | topic | file |
|---|---|---|
| 1 | The verification mindset | [01-verification-mindset.md](01-verification-mindset.md) |
| 2 | Testbench anatomy: driver, monitor, checker | [02-testbench-anatomy.md](02-testbench-anatomy.md) |
| 3 | Directed tests and verification plans | [03-directed-tests.md](03-directed-tests.md) |
| 4 | Reference models and trace comparison | [04-reference-models.md](04-reference-models.md) |
| 5 | Assertions (immediate and SVA) | [05-assertions.md](05-assertions.md) |
| 6 | Protocol verification (AXI as case study) | [06-protocol-verification.md](06-protocol-verification.md) |
| 7 | Coverage: measuring what you tested | [07-coverage.md](07-coverage.md) |
| 8 | Regression, configurations, and test plans | [08-regression.md](08-regression.md) |
| 9 | Debug methodology: a real bug, start to finish | [09-debug-methodology.md](09-debug-methodology.md) |
| 10 | Interview drill: questions, answers, UVM mapping | [10-interview-drill.md](10-interview-drill.md) |

## How to use this

Read a section, run its experiments, then close the file and explain the
concept out loud as if an interviewer asked.  DV interviews reward people who
can connect concepts ("what is a scoreboard?") to concrete experience ("here
is the scoreboard I wrote, here is a bug it caught").  Sections 3, 7, and 9
give you those stories.

Prerequisites: the repo builds (`cmake -S . -B build && cmake --build build -j`)
and the scripts in `scripts/` run.
