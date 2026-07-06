# Lab 2 Answers: Frontend

Files studied: `src/if_stage.sv`, `src/id_stage.sv`, `src/frontend.sv`.

## Experiment 1. Change `RESET_PC`

`RESET_PC` is a parameter on `dae_if_stage` (default `32'h0000_0000`),
threaded through `dae_frontend` and `Top`.  On reset both `pc_q` and
`req_pc_q` load it, so it decides the very first fetch address.

What you observe when changing it:

- Default `0x0`: the first two fetches hit the boot-ROM trampoline
  (`lui x1, 0x80000; jalr x0, 0(x1)`), which the memory model serves at
  0x0/0x4, and execution lands at `0x8000_0000` where programs are linked.
  The first commit trace lines show `pc=00000000`, `pc=00000004`, then
  `pc=80000000`.
- Set it to `0x8000_0000` (e.g. `-GRESET_PC=...` at Verilator build time, or
  by editing the instantiation): the trampoline is skipped and the first
  committed PC is `0x8000_0000` directly.  Programs still work because the
  linker script places `_start` there.
- Set it to an address with no code: the core fetches zeros
  (`32'h0000_0000` is not a valid RV32I encoding), decode sets `illegal`,
  and MEM converts it into a `HALT_ILLEGAL` halt (exit code 130).  This is a
  good demonstration that fault handling is *deferred*: fetch and decode
  do not trap, they annotate, and MEM decides.

## Experiment 2. Add logging for fetch PC and epoch

The natural probe point is the request handshake in `if_stage.sv`:

```systemverilog
if (imem_req_o.req_valid && imem_req_ready_i) begin
    $display("[IF] req pc=%08x epoch=%0d seq=%0d",
             pc_q, current_epoch_i, next_seq_id_i);
    ...
end
```

and the response acceptance/drop decision:

```systemverilog
if (outstanding_q && imem_resp_i.resp_valid) begin
    if (drop_q || redirect_valid_i || flush_i || req_epoch_q != current_epoch_i)
        $display("[IF] DROP pc=%08x req_epoch=%0d cur=%0d",
                 req_pc_q, req_epoch_q, current_epoch_i);
    ...
end
```

What the log shows around a taken branch: the epoch increments (managed in
`frontend.sv` on `redirect_valid_i`), the next fetch request goes to the
redirect target with the new epoch, and any response still in flight for the
old epoch is printed as a DROP — the packet is thrown away in IF and never
reaches the IR queue.  This is Lab 7's mechanism, visible one packet at a
time.

## Experiment 3. Observe the IR queue filling while backend issue is blocked

Setup: any long-latency backend event blocks issue; the easiest is a load
followed by a dependent instruction (issue stalls on the hazard), or run on
the `+HEX` cache path where a D-cache miss holds MEM for a full AXI
fill.

What happens, structurally:

- IF keeps one request outstanding at a time (`outstanding_q`) and only
  launches when its output buffer is free (`!out_q.valid && out_ready_i`).
- ID is combinational and pushes into the IR queue
  (`fifo #(DEPTH=4)` in `frontend.sv`).
- While the backend refuses to issue (`ir_ready_i=0`), the queue count
  climbs to 4, `in_ready` drops, ID backpressures IF
  (`in_ready_o = out_ready_i`), IF's output buffer stays occupied, and IF
  stops requesting.  Total frontend run-ahead: 4 queue entries + 1 IF output
  buffer + 1 outstanding request ≈ 6 instructions.
- When the backend unblocks, the queue drains one per cycle while IF starts
  refilling from the back — for a few cycles the backend issues at full rate
  from buffered instructions even though fetch has not caught up yet.

That is the "decoupled" in DAE: the queue converts fetch latency and
backend stalls from lockstep bubbles into slack that each side absorbs
independently.
