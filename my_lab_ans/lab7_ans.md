# Lab 7 Answers: Epoch And Token Recovery

Files studied: epoch fields in `include/uarch.svh`, epoch management in
`src/frontend.sv`, response filtering in `src/if_stage.sv`, stale IR queue
drain in `src/frontend.sv`.

## The idea in one paragraph

Instead of physically deleting wrong-path state on a redirect, every packet
carries its generation (`epoch`, 2 bits) and age (`seq_id`, 8 bits).  A
redirect just increments the frontend's `current_epoch_q`.  Old state is
allowed to keep existing — it simply fails validity checks wherever it next
shows up, and each holder discards it locally.  Deletion becomes lazy and
distributed instead of a global synchronous flush wire fanned out to every
buffer.

Four places enforce it:

1. **In-flight fetch responses** (`if_stage.sv`): a response is dropped when
   `drop_q` is set (a redirect happened while the request was outstanding)
   or `req_epoch_q != current_epoch_i`.  The memory system needs no
   cancel/abort port — the wrong-path response completes normally and dies
   at the boundary.
2. **IR queue head** (`frontend.sv`): `queue_stale` pops entries whose epoch
   is old, one per cycle, without presenting them to issue.  The FIFO's
   physical `flush` port is tied off; validity does the work.
3. **Backend tokens** (`backend.sv` / `uarch.svh`): a redirect builds a
   `kill_event_t{epoch, seq_id}` and `kill_token_if_younger()` marks every
   younger token `killed` at the stage boundaries.  Killed tokens still flow
   (simplest control), but commit nothing.
4. **Scoreboard rows** mirror the same kill so a dead producer cannot stall
   or feed a live consumer.

`seq_after()` compares 8-bit sequence numbers on the wrap-safe half-circle,
the same trick TCP uses; 2 epoch bits are safe because state from an epoch
can only be confused after four further redirects, by which point the
bounded frontend (≤ ~6 packets of run-ahead) has provably drained it.

## Experiment 1. Force branches to redirect often

Any branchy workload works; the mergesort RTOS test is ideal because
FreeRTOS context switches also redirect via `mret`.  A tight loop is the
minimal case — every back-edge is a taken branch, so every iteration pays a
redirect.  What to look for in the commit trace: no committed PC ever
belongs to the not-taken path behind a taken branch, even though those
instructions demonstrably entered the pipe (they were fetched — the IR queue
had them).  They died as killed tokens or stale queue entries.

## Experiment 2. Add debug prints for current epoch and packet epoch

Suggested probes:

```systemverilog
// frontend.sv — the moment a generation dies
if (redirect_valid_i)
    $display("[FE] epoch %0d -> %0d", current_epoch_q, current_epoch_q + 1'b1);

// frontend.sv — stale entries evaporating
if (queue_stale)
    $display("[FE] drain stale pc=%08x epoch=%0d cur=%0d",
             queue_ir.pc, queue_ir.epoch, current_epoch_q);

// if_stage.sv — wrong-path responses dropped (see lab2_ans.md)
```

The signature pattern after one taken branch: one `epoch a -> a+1` line,
zero to one dropped IF response, up to ~4 drain lines (whatever the queue
held), then fetch lines with the new epoch.  Every wrong-path instruction is
accounted for by exactly one drop/drain/kill — nothing needs to be found
and erased in place.

## Experiment 3. Confirm stale queue entries do not issue

Two independent guards make this checkable:

- `ir_valid_o = queue_valid && !flush_i && !queue_stale` — the frontend
  never presents a stale head to the backend at all.
- Even if one slipped through, the backend's `kill_event` epoch/seq check
  would mark it killed before commit, and `wb_stage.sv` gates `rf_we_o`
  and `store_valid` on `!killed`.

A stronger check than eyeballing: the ISA regression itself.  Several
`rv32ui` tests are dense with taken branches, and any stale issue would
corrupt an architectural register and fail the test signature — 58/58
passing is the standing proof.  For a targeted proof, add a temporary
assertion in `backend.sv`:

```systemverilog
assert (!(commit_valid_o && wb_q.epoch != /* epoch at issue time */));
```

or simply `$display` any commit whose epoch differs from the epoch it was
issued with — it never fires.

## Why this beats physical flushing (the lab's real question)

A physical flush must reach every buffer that might hold wrong-path state,
in the same cycle, including state *in flight inside the memory system*
where no flush wire can go.  Epochs make each holder self-cleaning, which is
why the same mechanism kept working unchanged when the memory subsystem
added multi-cycle, variable-latency fetches underneath the core — an
in-flight I-cache miss for the wrong path just returns and gets dropped by
the epoch filter, exactly like the 1-cycle case.  The mechanism scales to
out-of-order designs (it is a primitive form of what full cores do with
branch tags), which is the point of teaching it before Lab 8.
