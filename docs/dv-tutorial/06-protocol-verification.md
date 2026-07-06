# Section 6: Protocol Verification — AXI As Case Study

## The method: turn the protocol spec into a checklist

A bus protocol is a contract with enumerable rules.  Protocol verification
is the discipline of (1) extracting the rules from the spec into a
checklist, (2) classifying each rule by *who* can violate it (master, slave,
or interconnect), and (3) implementing each as an assertion or monitor
check at the interface.  The output artifact is a **protocol checker** —
in industry usually purchased as VIP (verification IP) and bound onto every
AXI interface in the design; here, something you can write and understand.

## The AXI4 rule checklist (the subset that matters here)

Handshake rules (per channel — AW, W, B, AR, R):

| rule | violator | check |
|---|---|---|
| `valid` must not depend combinationally on `ready` | source | design review / formal |
| once `valid`, hold until `ready` (no retraction) | source | `valid && !ready \|=> valid` |
| payload stable while `valid && !ready` | source | `$stable(addr/data/len/...)` |
| `ready` may assert/deassert freely before `valid` | — | (permission, not obligation) |
| no `X` on `valid`, or on payload when `valid` | source | `!$isunknown(...)` |

Transaction rules:

| rule | violator | check |
|---|---|---|
| exactly `awlen+1` W beats per AW, `wlast` on final beat only | master | beat counter in monitor |
| exactly `arlen+1` R beats, `rlast` on final | slave | beat counter |
| one B response per AW/W burst, after the last W beat | slave | outstanding counter |
| `bid`/`rid` must match an outstanding `awid`/`arid` | slave | ID table |
| same-ID responses return in request order | slave | per-ID FIFO of expectations |
| 4KB boundary must not be crossed by a burst | master | address+len arithmetic |
| write data interleaving (WID) — removed in AXI4: W beats follow AW order | master | ordering check |

Knowing *which side* each rule binds is an interview differentiator: e.g.,
payload stability binds the cache (master) on AW/AR/W and the DRAM model
(slave) on B/R.

## How this design satisfies the hard rules structurally

The best protocol compliance is compliance **by construction** — being able
to point at the structure that makes a violation impossible:

- **Beat counts**: the cache's `wlast = (beat_q == LINE_WORDS-1)` and the
  DRAM model's `rlast = (rcnt_q == rlen_q)` tie last-beat generation to the
  same counter that indexes data, so count and marker cannot diverge.
  Unit-test 8 (write-back then re-read through a fill) is the end-to-end
  proof: any beat-count error corrupts the round trip.
- **No interleaving**: the arbiter holds a grant for the entire burst
  (`W_ADDR → W_DATA → W_RESP` before re-arbitrating), so W beats from two
  masters cannot interleave even though two masters exist.  One sentence of
  FSM design retires an entire rule class.
- **Response routing**: the arbiter stamps the master index into
  `awid`/`arid` and routes `B`/`R` back by grant state; with one
  outstanding transaction per side, ID-order rules cannot be violated —
  *yet*.  The day the caches go multi-outstanding, the ID-ordering rules
  above become live; a verifier keeps that list of "dormant rules armed by
  future features."

"By construction" still gets assertions — structures get edited; the
assertion is what notices when a refactor breaks the construction.

## Back-pressure: the great protocol bug generator

Most real AXI bugs are not in the happy path; they appear when `ready`
stalls at an inconvenient beat (payload changes while waiting, counters
skip, FSMs sample stale data).  The current `axi_dram_model` is always
ready in its accepting states — friendly stimulus (section 1).  The
protocol-verification upgrade is a **delay-injecting slave**: parameterize
the model to deassert `awready`/`wready`/`rvalid`-advance for
pseudo-random cycles.  Combined with the stability assertions of section 5,
this converts the unit test into a genuine protocol stressor: stimulus
creates the hazardous windows, assertions observe them (the triad again).

## Layered checking at a protocol boundary

At a bus interface the layers stack like this — each catches what the layer
below cannot express:

1. signal legality (no X, handshake rules) — assertions
2. transaction integrity (beat counts, IDs, boundaries) — protocol monitor
3. transaction *content* (right address, right data) — scoreboard vs. model
4. transaction *policy* (round-robin fairness, QoS, no starvation) —
   directed tests + functional coverage

Unit-test 9 (concurrent misses both served) is a layer-4 check; the AW/AR
counters are layer 2/3; the section-5 assertions are layer 1.  Naming the
layers when asked "how do you verify a bus interface" structures the whole
answer.

## Experiment

Write the W-beat counter monitor: in `tb_mem_subsys.sv`, count
`wvalid && wready` beats between an AW handshake and the corresponding
`wlast`, and `$fatal` if the count differs from `awlen+1` or if a beat
arrives with no AW outstanding.  Then inject the classic bug: in
`cache.sv`'s `WB_DATA` state, make `wlast` fire at `LINE_WORDS-2`.  The
data checks of tests 7/8 *also* catch this (corrupted write-back), but
notice what differs: your monitor fails **at the guilty beat** with "3
beats, expected 4", the data check fails thousands of ns later with
"wrong data" — the localization argument for protocol checkers, live.
Revert after.

## Interview angle

- "Verify an AXI interface" → the checklist above, classified by
  handshake/transaction/content/policy layers, plus back-pressure stimulus
  and VIP binding.  Mention 4KB boundaries and ID ordering unprompted.
- "What is VIP and why buy it?" → a pre-verified protocol agent
  (driver+monitor+checker+coverage); you buy the thousand corner-case
  rules someone else already encoded.
- "The design only ever does full-line bursts — do you still check the
  protocol?" → yes: rules bind *interfaces*, not current usage; the checker
  is armor against the next feature (multi-outstanding, partial lines).
