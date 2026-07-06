# Lab 1 Answers: Types, FIFO, And Decoder

Files studied: `include/uarch.svh`, `src/fifo.sv`, `src/decoder.sv`.

## Q1. What information must decode preserve for later stages?

Everything any later stage will ever ask about the instruction, so that no
stage after ID ever looks at raw bits again.  Concretely, `decoded_ir_t`
carries four groups of information:

1. **Identity** — `pc`, `raw_inst`, `epoch`, `seq_id`.  The PC is needed for
   branches/AUIPC/trap `mepc`; epoch and seq_id are the instruction's "who am
   I" for the kill/recovery machinery (Lab 7).
2. **Routing** — `fu_type` (INT/BRANCH/CSR/LOAD/STORE/SYSTEM) plus the
   per-unit operation fields: `alu_op`, `alu_op1_sel`/`alu_op2_sel`,
   `branch_op`, `sys_kind`, `mem_len`/`load_signext`, `csr_addr`/
   `csr_source_imm`/`csr_source_is_imm`/`csr_writes`.
3. **Dependencies** — `rs1_use`/`rs1_idx`, `rs2_use`/`rs2_idx`,
   `rd_to_write`/`rd_idx`, and the materialized `imm`.  The scoreboard makes
   every issue decision from these fields alone.  The `*_use` flags matter:
   an instruction that doesn't read rs2 must not stall on a stale rs2 index.
4. **Faults observed so far** — `illegal`, `if_bus_error`.  Decode does not
   act on them; it records them so MEM can turn them into halts in program
   order, at one central place.

The rule of thumb: if a downstream stage would need to inspect
`raw_inst[x:y]` to decide something, that decision belongs in the decoder and
its result belongs in `decoded_ir_t`.  (The one deliberate exception today:
EXE peeks at `raw_inst[6:0] == OPCODE_JALR` to select the redirect target —
a candidate for a proper `is_jalr` decode bit.)

## Q2. Why should downstream stages avoid re-decoding raw instructions?

- **Single source of truth.**  If EXE and MEM each re-derived "is this a
  load?" from raw bits, the two copies could disagree after an edit, and the
  bug would only show on the instruction encodings where they diverge.  With
  one decoder, an encoding question has exactly one answer.
- **Uniform tokens enable uniform control.**  Kill, stall, and trap logic
  treat every instruction as the same `inst_token_t` shape.  That is what
  lets `kill_token_if_younger()` be one function applied at every stage
  boundary instead of per-stage special cases.
- **Timing.**  Decoding is a wide mux tree over 32 bits.  Doing it once in ID
  keeps it off the EXE/MEM critical paths, which already contain the ALU and
  the D-memory interface.
- **It scales toward harder designs.**  Renaming, ROBs, and replay all key
  off decoded fields.  Building the "decode once, carry fields" discipline
  now is the cheap time to do it.

## Q3. What does `out_valid = !empty && !flush` protect against?

(In `fifo.sv`: `assign out_valid = (count_q != '0) && !flush;`)

It protects the consumer from acting on queue contents **during the same
cycle a flush arrives**.  The pointer/count reset happens at the clock edge
(`always_ff`), so without the combinational `!flush` term there is a
one-cycle window where the FIFO still *looks* full of pre-flush entries and
the consumer could pop and execute an instruction that is being invalidated
that very cycle.  Gating `out_valid` makes the queue appear empty
immediately, while the actual state cleanup completes at the edge.

Also note `push = in_valid && in_ready && !flush`: the producer side is
gated the same way, so an in-flight packet from the dying generation cannot
slip in while the FIFO resets.

Interestingly, the frontend's IR queue instance ties `flush` to `1'b0` and
handles invalidation a different way — entries carry an epoch and the stale
head is drained by comparison (`queue_stale` in `frontend.sv`).  Comparing
the two mechanisms is the point of Lab 7: physical flush deletes state,
epoch validity lets state expire.
