# Lab 5 Answers: Memory And Stalls

Files studied: `src/lsu.sv`, `src/load_data_filter.sv`, `src/mem_stage.sv`.

## Background: the MEM request protocol

MEM is single-outstanding by construction.  `req_sent_q` records that the
request has been accepted (`req_valid && req_ready`); the stage stalls
(`stall_o`) until `req_sent_q && resp_valid`.  `req_sent_q` clears when the
pipeline advances or on flush.  This little state machine is the seed the
memory subsystem's cache FSM was later grown from — same shape, more states.

The LSU (`lsu.sv`) turns size+address into byte enables and replicated/
shifted store data *before* the bus (so memory never needs to know about
lanes); `load_data_filter.sv` does the inverse on the way back
(lane select + sign/zero extension).  Misalignment is detected
combinationally from `addr[1:0]` and the access never reaches the bus.

## Experiment 1. Add artificial D-memory latency

Two ways to do it:

- **Hack**: in `tb_top.sv`'s response `always_ff`, hold `resp_valid` low for
  N cycles after each request (a small counter).
- **Real**: run the `+HEX` path — the cache/AXI/DRAM hierarchy provides
  genuine variable latency: ~3 cycles on a hit, tens of cycles for a miss
  (AR + 4 R beats), roughly double for a dirty-eviction miss (AW + 4 W + B
  first).  See `docs/mem-subsys.md`.

Expected observation, either way: **results do not change, only cycle counts
do.**  The handshake (`req_valid/req_ready` in, `resp_valid` back whenever)
never assumes fixed latency; `stall_o` simply holds the pipeline longer.
This latency-insensitivity is why the cache could be spliced in underneath
the core without touching a single pipeline file — and it is verified: the
same ISA tests pass on the 1-cycle DPI path and (via `tb/smoke.hex` and the
mem-subsys unit test) through the multi-cycle cache path.

The one thing that must *never* appear with any latency: a repeated request.
`req_sent_q` guarantees each memory operation issues exactly one bus
transaction — watch `dmem_req.req_valid` while stalled and confirm it stays
low after acceptance.  (A store that issued twice would be a correctness
bug, not a slowdown.)

## Experiment 2. Watch WB drain while MEM stalls

In `backend.sv`:

```systemverilog
if (mem_stall) begin
    wb_q <= '0;          // WB gets a bubble; EXE/MEM hold
end else begin
    wb_q <= next_wb_pkt; ...
end
```

While MEM waits for a response, the instruction currently in WB commits
normally on the first stall cycle, and then WB receives bubbles.  So a MEM
stall does not freeze the whole backend rigidly: older work *drains*,
younger work *holds*.  In the commit trace this shows up as commit gaps
exactly matching D-memory wait cycles.

Why it matters: the older instruction retiring during the stall is what
updates the WB scoreboard row / register file, so a dependent instruction
waiting at issue can get its value (via WB forwarding or the regfile) while
MEM is still busy — stalls overlap with hazard resolution instead of
serializing after it.

## Experiment 3. Load-use behavior with forwarding on and off

Mechanism first: a load in the MEM row is only forwardable once its data
has actually arrived — `rd_ready_o = (req_sent_q && resp_valid)` for loads.
So the load-use penalty has two independent parts:

1. wait for the data to exist (memory latency; forwarding-independent), and
2. wait for the data to become *reachable* (which row it is in, and whether
   that row's forwarding path is enabled).

With `MEM_FORWARDING=1` the consumer issues in the same cycle the load's
response lands (forward from `mem_result_bus`).  With it off, the value must
progress to the WB row (+1 cycle) or all the way to the register file
(+2 cycles, if `WB_FORWARDING=0` too).

Measured on `my_fib` (full table and method in `lab3_ans.md`): disabling
both forwarding paths costs 3,933 cycles over 59,098 instructions (+2.1%);
loads are the main reason the WB path (+2,335 alone) outweighs the MEM path
(+268 alone) — many load consumers cannot use MEM forwarding anyway because
the data has not arrived by the time they first check.
