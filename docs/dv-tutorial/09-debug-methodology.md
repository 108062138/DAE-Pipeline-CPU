# Section 9: Debug Methodology — A Real Bug, Start To Finish

This section replays, command by command, the debug of a real bug found in
this repo: the FreeRTOS mergesort test hanging.  Every artifact is still
here, so you can re-run the whole investigation (revert the fix in
`src/mem_stage.sv` per section 1's experiment).  The bug is real, the
method is general, and the story is interview gold if you can tell it with
the *reasoning*, not just the conclusion.

## Step 0: A failure, made loud and reproducible

```text
./scripts/run-my-mergesort-rtos.sh
...
sorted[0] = 1
%Fatal: tb_top.sv: Assertion failed: timeout after 400000 cycles
```

Deterministic (same hang every run) and loud (watchdog `$fatal`, nonzero
exit).  If either had been false, *that* would be the first task — an
unreproducible or silent failure cannot be debugged, only feared.
Also bank the phenomenology: three tasks started, output stopped after the
first merged element.  Partial progress means boot, scheduler, queues, and
printf all basically work — this is a *dynamics* bug, not a bring-up bug.

## Step 1: Observe at the highest abstraction first

Not waveforms — the commit trace (the architectural transaction log,
section 4).  Re-run without `+QUIET`, look at the tail:

```text
commit pc=80006edc rd=0 ... trap=0
commit pc=80006edc rd=0 ... trap=0     <- same PC, forever
```

One PC repeating unboundedly = livelock at a single instruction.  The
questions write themselves: *what* instruction, and *why is executing it
not making progress?*

## Step 2: Cross-reference to source reality

```sh
riscv64-elf-objdump -d build/my_mergesort_rtos/my_mergesort_rtos > /tmp/dis
grep -B8 "^80006edc" /tmp/dis
```

`80006edc: mret` — the last instruction of the FreeRTOS trap handler's
restore sequence.  An `mret` that loops to itself means `mepc == 0x80006edc`
— `mepc` holds the mret's *own address*.  Now the question sharpens: *who
wrote that value into mepc?*

## Step 3: Work backward through the evidence, not forward through guesses

The trace is grep-able history.  Hunt the corrupted value as data:

```sh
grep "store=1 .* store_data=80006edc" trace.log
#  -> pc=80006d9c  sw ... (the handler's context-save writing mepc to the task stack)
grep -n "pc=80006edc .*trap=1" trace.log | head -1
#  -> the FIRST time an interrupt was taken ON the mret itself
```

Two facts converge: a timer interrupt (`cause=80000007`) was taken *with
the mret as the interrupted instruction*, so trap entry wrote
`mepc <= mret's PC`; the handler then faithfully saved that poisoned mepc
as a task's resume point.  Every later resume of that task executes
`csrw mepc, 80006edc; mret` — a permanent self-loop.  The OS is innocent;
it preserved exactly what the hardware gave it.

## Step 4: Indict with the spec, then localize in the RTL

Architectural argument (this is the step that separates debugging from
flailing): inside the handler `mstatus.MIE = 0`; the `mret` is the very
instruction that re-enables interrupts; therefore no interrupt may ever be
attributed to the mret itself — only to its *target*.  The observed trace
is impossible on a correct core.  Now, and only now, read RTL with a
specific question: *where does the interrupt-take decision see MIE=1 while
the mret is still in flight?*

- `exe_stage.sv`: `mret_commit` fires in EXE → CSRFile updates
  `mstatus.MIE` at the next edge.
- `mem_stage.sv`: async-interrupt check reads *current* `csr_mstatus_i`
  and attributes the trap to whatever token is in MEM.
- Pipeline the two: the cycle after EXE, **the same mret token is in MEM**,
  MIE is freshly 1, MTIP is pending → interrupt taken on the mret.
  A one-cycle window between side-effect commit (EXE) and trap attribution
  (MEM).

Note the generalization found *during* localization: any CSR write that
enables interrupts has the same window (it would re-execute after the
handler — double-applying the write).  Root-causing means finding the
*class*, not the instance.

## Step 5: Fix at the cause, prove at every level

The fix states the invariant, not a patch for the symptom: async interrupts
must not be attributed to tokens whose side effects already committed in
EXE (`FU_CSR`, `SYS_MRET`) — the interrupt stays pending and lands on the
next live token (`src/mem_stage.sv`, with a comment explaining *why*).

Then the proof obligations, in order: the failing test passes
(mergesort → full sorted output, PASS); nothing else broke (58/58 ISA,
fib, fib-rtos, freertos-demo, unit test — section 8's matrix); and the
knowledge is banked — the write-up in `docs/mem-subsys.md`, the mergesort
script as the permanent regression, and (section 5) the assertion you now
wish had existed, which would have fired at the guilty cycle instead of
300k cycles later.

## The method, extracted

1. Make it reproducible and loud, or do that first.
2. Observe top-down: architectural trace before waveforms; waveforms when
   the question is *sub-cycle* (here, never needed — know when they are:
   combinational races, X-propagation, handshake glitches).
3. Find the first moment history goes wrong (grep the trace as data;
   binary-search time if the trace is huge).
4. Convict with the spec — state why the observation is *impossible*, not
   just surprising.
5. Read RTL only with a specific question in hand.
6. Fix the class; add the missing assertion; re-run everything; write it
   down.

The same protocol handles the other two suspects from section 1: if step 4
finds the observation *legal*, your checker or your spec-reading is the
bug — and steps 1-3 already produced the evidence to show which.

## Interview angle

- "Tell me about a hard bug" — this story, in STAR form, 90 seconds:
  *Situation*: RTOS test hung after passing 4 suites.  *Task*: root-cause a
  livelock.  *Action*: commit-trace archaeology → interrupt taken on mret →
  one-cycle EXE/MEM side-effect window.  *Result*: one-line class fix, full
  regression green, new permanent test + assertion.  Practice it aloud.
- "Waveforms or logs first?" → logs/traces (searchable, whole-run);
  waveforms for sub-cycle questions once localized to a window.
- "Design bug or testbench bug — how do you tell?" → step 4: the spec
  argument.  You should be able to argue *both* directions convincingly.
