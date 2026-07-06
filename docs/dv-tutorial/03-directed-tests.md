# Section 3: Directed Tests And Verification Plans

## From spec to test: the verification plan

A directed test suite is not a pile of scenarios — it is a **verification
plan** made executable.  The plan is a table with one row per specified
behavior, and three mandatory columns:

| behavior (from spec) | stimulus that activates it | observation that proves it |

Writing the third column is the skill.  "Read returns correct data" is a
weak observation — many broken designs return correct data.  The strong
version adds *structural* observations: counters, state, traffic.

## Worked example: the plan behind `tb_mem_subsys.sv`

The cache/arbiter spec ("write-back, write-allocate, direct-mapped, burst
per line, round-robin arbiter") decomposes into exactly the checks the bench
implements.  Reconstructing the plan from the test (or vice versa) is a
great interview exercise:

| # | behavior | stimulus | observation |
|---|---|---|---|
| 1 | miss fills a line from memory | I$ read to cold address | data correct **and** `ar_count == 1` |
| 2 | hit serves from the array | second read, same line | data correct **and** `ar_count` unchanged |
| 3 | address decoding (tag vs. wrap) | read `0x8000_0000` after `0x0` | different data, second AR burst |
| 4 | write miss allocates, doesn't write through | D$ write to cold address | an AR happens, **no AW** |
| 5 | write merged into line | read back after write | merged data, zero AXI traffic |
| 6 | byte enables respected | 1-byte write, word read back | only addressed lane changed |
| 7 | dirty eviction writes back first | conflicting read (same index, new tag) | exactly one AW **and** one AR |
| 8 | write-back data is not lost | re-read the evicted address | original merged data returns |
| 9 | arbiter serves both masters | concurrent I$ + D$ misses (`fork/join`) | both correct, `ar_count += 2` |

Note the shape: each row's observation names a *count* or a *change*, not
just a value.  Test 4/7's AW counting is what caught the injected dirty-bit
bug in section 7's mutation experiment — a data-only test would have missed
it until eviction, and a data-only test *without* the conflict scenario
would never have caught it at all.

## Rules for directed tests that stay valuable

1. **Self-checking, always.**  Pass/fail is computed in the test and
   signaled mechanically (`$fatal` → nonzero exit code → scripts and CI see
   it).  A test whose result requires reading a log is a test that will
   silently rot.
2. **A watchdog is part of self-checking.**  Liveness failures (deadlock,
   livelock, lost request) don't produce wrong data — they produce
   *nothing*.  The 20k-cycle `$fatal` timeout converts "nothing" into a
   failure.  The mret livelock was caught exactly this way at system level.
3. **Order tests from simple to compound, but keep independence in mind.**
   The bench runs scenarios sequentially on warm state (test 5 depends on
   test 4's write).  That's economical but means one failure can cascade;
   know the trade-off and be able to defend either choice.
4. **Test the negative space.**  What must *not* happen is spec too: "no AW
   on write hit", "no traffic on hit".  Absence checks need counters or
   assertions — you cannot eyeball something not happening.
5. **Every fixed bug becomes a directed test.**  `run-my-mergesort-rtos.sh`
   is now the permanent regression for the mret bug.  If it's not in the
   suite, the bug is allowed to come back.

## What this plan deliberately does not cover (know your holes)

Honest verifiers enumerate their own gaps — interviewers push on this:

- **Error responses**: nothing makes the DRAM model return `SLVERR`, so the
  cache's `err_q` path is dead in the bench (confirmed by toggle coverage in
  section 7).  Fix: an error-injection knob in `axi_dram_model`.
- **Back-pressure**: the DRAM model is always ready in its accepting states;
  no test stalls `awready`/`rready` mid-burst.  A delay-randomizing slave
  would cover the FSM's wait arcs.
- **Same-cycle arbitration race**: test 9 forks both misses but doesn't
  sweep their relative launch cycle.  A loop over offsets (-3..+3 cycles)
  would.
- **Aliasing sweeps**: one conflict pair, not a sweep over all index bits.

## Experiment: extend the plan

Add row 10 — "unaligned-within-line accesses hit the right word": write
`0x104`, `0x108`, `0x10c`, read each back, assert `ar_count` unchanged after
the first line fill.  Then add row 11 for something harder: after a dirty
eviction (test 7), write to the *new* line and evict it again — proves
dirty tracking survives line replacement (`dirty_q` cleared on fill,
re-set on write).  Wire them into `tb_mem_subsys.sv` following the existing
task style and run `./scripts/run-mem-subsys-test.sh`.

## Interview angle

- "How would you verify a cache?" → recite the plan table above from
  memory; it *is* the expected answer (hit, miss, allocate, evict, byte
  enables, no-traffic-on-hit, writeback data integrity, plus the holes
  list).
- "How do you know your test actually checks anything?" → negative space,
  structural counters, and mutation testing (section 7).
- "Directed or random first?" → directed for bring-up: fastest path to
  first failure, and the plan's rows are needed as CRV coverage points
  later anyway.
