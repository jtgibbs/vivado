# CDC Corruption — Artix-7 / Vivado port

A prior iCE40 project proved this failure **on real hardware**: one async counter
read five ways, three of them wrong, tearing tens of thousands of times a second
(numbers below). What it could not prove was anything about the *tools*. The
open iCE40 flow does do per-clock static timing — `nextpnr` reports both domains
passing — but it has no CDC checker, no way to *express* a clock relationship,
and no report of the crossings between domains. It built an unsynchronized
crossing without a single warning.

This port runs the identical RTL through Vivado to answer the other half:
**what does a real STA and CDC flow say about a design whose bugs you already
know?**

That framing is the point. A CDC report on unfamiliar code tells you what the
tool noticed, never what it missed. Run it first against a known-answer design —
three planted bugs, two correct references — and you learn where the tool's
blind spots are before you trust it on something that matters.

## The prior result this is calibrated against

Measured on an iCEBreaker V1.1a (iCE40UP5K), 12 MHz crystal against `SB_HFOSC`,
hardware tear counters sampling continuously. A coherent read steps by a small
bounded amount each clock; a torn read jumps:

```
naive_direct    :  46,078 torn reads/s   <- values the counter never held
naive_2flop     :  46,078 torn reads/s   <- per-bit 2FF is EXACTLY as broken
gray + 2FF sync :       0 torn reads/s   <- correct
gray, NO sync   : 113,893 torn reads/s   <- gray without a synchronizer: WORSE
```

Three findings, and they are why this design is a good calibration target:

1. **Per-bit 2-flop synchronization is no better than naive** — identical count.
   It kills metastability per *bit*; multi-bit **coherence** is a separate
   problem, and the assembled word is one the counter never held.
2. **Gray coding does not remove the need for a synchronizer.** Gray fixes
   coherence, flops fix metastability — orthogonal, and you need both. Gray with
   no synchronizer is *worse* than naive because that path decodes
   *combinationally before* capturing: the XOR cascade turns a single-bit gray
   transition into a multi-bit binary one, and the spread is structural —
   `bin[23]` is a bare wire while `bin[0]` is the XOR of all 24 gray bits, so
   logic depth is graded across the bus by construction. Metastability may
   contribute, but the coherence argument alone accounts for it and a tear
   counter cannot apportion the two.
3. **It looks fine ~99.5% of the time.** That is exactly why these bugs pass
   casual testing and fail in the field.

The RTL that produced those numbers is in [`rtl/`](rtl/), byte-identical, with
digests and source commit recorded in [`rtl/PROVENANCE.md`](rtl/PROVENANCE.md).
The iCE40 repo is private; the numbers above and the digests are what let this
project stand on its own.

## What is actually ported

| | |
|---|---|
| `rtl/corrupt.v`, `readout.v`, `cdc_capture.v`, `uart_rx/tx.v` | **byte-identical copies** of the iCE40 sources |
| `top_a7.v` | new — the only vendor-specific file there ever was |
| `cdc_corruption_a7.xdc` | new — pins, clocks, and the CDC constraints |

**This directory is standalone.** `rtl/` holds copies rather than `../`
references, so `rsync -a cdc_corruption_a7/ instance:` is the entire deployment
step — no repo, no symlinks, nothing to resolve on the far end.

Vendoring costs something, though: the whole claim here is that Vivado is being
handed the *unchanged* RTL, and a silently diverged copy turns that claim into a
lie. So it is checkable rather than asserted —

```bash
make check-sync
```

diffs every file in `rtl/` against its iCE40 original and fails on drift. It needs
a checkout of the (private) source repo — `make check-sync
ICEBREAKER=/path/to/icebreaker` — and skips cleanly when there isn't one, which
is the normal state here and on the instance. For verification without any
access to that repo, [`rtl/PROVENANCE.md`](rtl/PROVENANCE.md) carries SHA-256
digests and the exact source commit.

The async clock is the one real design decision. `SB_HFOSC` has no Artix-7
equivalent, and the two candidates are not interchangeable:

- **`ASYNC_SRC = "EXT"`** (default) — a PMOD pin, driven by the testbench.
  This is what makes the Vivado detour worth taking: the testbench owns the
  phase relationship and can *walk* the async edge through the capture flop's
  setup/hold window deliberately, instead of waiting for two oscillators to
  drift into it.
- **`ASYNC_SRC = "STARTUP"`** — `STARTUPE2`'s `CFGMCLK`, the ~65 MHz internal
  configuration ring oscillator. The true `SB_HFOSC` analogue: free-running,
  untrimmed, unrelated to the board crystal. Use this for a standalone board run.

**Not an option: a second MMCM output.** It would look like a separate clock but
is phase-related to the source, so Vivado times the crossing as synchronous. The
result would be a demo that never tears and a timing report that says everything
is fine — precisely the failure this project exists to expose.

## The three environments disagree, usefully

| | naive reads look like |
|---|---|
| behavioral simulation | **perfect** — no setup/hold model, every sample deterministic |
| behavioral + injected skew | **wrong numbers** — real mechanism, meaningless rate |
| post-implementation timing sim | **X** — SDF `$setuphold` fires, SIMPRIM drives unknown |
| iCEBreaker hardware | **wrong numbers** — 46,078/s naive, 113,893/s gray-no-sync |

Behavioral sim is the lie the iCE40 cocotb testbench already documents. Timing
sim is the tool admitting it cannot know. Hardware is the truth. X is not what
silicon does — silicon resolves to *some* value, and that value is what the
board measured; X is the simulator refusing to guess. Read it as "this bit was
unknowable" and go to the board for what it resolves to.

This is why post-implementation timing simulation is the piece worth having and
the piece almost nobody runs. It is the only simulation that models the
*preconditions* — real setup/hold windows on a routed netlist. It still does not
model metastability resolving, which is why its answer is X rather than a value.

## Use

One target runs on the Mac. Everything else needs Vivado, so it runs on the EC2
instance.

```bash
make smoke
```

Icarus against stub `BUFG`/`STARTUPE2` models, about a second. It cannot find a
CDC failure — no behavioral simulation can — but it elaborates the real RTL and
exercises the testbench's UART model and the whole register map, which is where
the bugs that waste a round trip to the instance actually live. It already
earned its keep: the first version of the testbench silently dropped every reply
byte after the first read, because `uart_rx` asserts `valid` at the centre of
the stop bit, one full bit time before the host finishes shifting the frame out.
The DUT starts replying while the host is still transmitting, so a receiver that
only listens after its `send()` returns has already missed the start bit. The
fix is a free-running receive monitor feeding a queue. Nothing about that bug is
Xilinx-specific, and finding it on EC2 would have cost a Vivado run.

Then, on the instance:

```bash
make all
```

`behav` → `synth` (+ CDC audit) → `impl` → `timing`, one command. Or a stage at
a time:

```bash
make behav
```

```bash
make synth
```

```bash
make impl
```

```bash
make timing
```

```bash
make cdc
```

Waveforms land in `build/cdc_corruption_a7.vcd` (`make wave` — prefers Surfer,
falls back to GTKWave; see the Makefile note on why GTKWave is dead on macOS 26),
reports in `build/cdc/`, and the routed checkpoint opens in the GUI over DCV
with `make gui`.

`make smoke` dumps the full hierarchy, which is what you want on a design this
small. The Vivado runs default to `DUMP_DEPTH=2` — testbench plus DUT ports —
because a full dump of an SDF-annotated routed netlist runs to gigabytes.

## Trapping the event instead of hunting for it

Scanning a 5 MB waveform for a transient is the wrong tool. `make trap` makes
the simulator stop *at* the first tear and dump only that.

```bash
make trap
```

Three things make it work.

**The trigger is a pin, not a hierarchical name.** `top_a7` drives `led[3:1]`
from the tear counters, so "has anything torn yet" is observable at the top
level. That is the only form of trigger that survives the trip to timing
simulation: in the post-implementation netlist `tear_nd` is not a bus, it is 32
separately-named flops, and a testbench hierarchical reference into it would
break. The same trigger works unchanged in behavioral sim, in timing sim, and on
the board.

**Two passes, because a VCD cannot rewind.** Nothing can decide to start dumping
after the interesting thing already happened. Pass 1 dumps nothing and reports
when the first tear occurred; pass 2 re-runs and dumps ±200 ns around it. This
is sound only because the testbench is deterministic — no `$random`, a fixed
phase sawtooth — so the same build triggers at the same simulated instant every
time. Don't introduce randomness without revisiting that.

**It prints the event, not just plots it.** The waveform says *when*; the
trigger's `$display` says *which path tore and what impossible value it
produced*.

Measured on the behavioral smoke run, triggering on an exact counter value:

```
TRIGGER  hf_count reached 001000 at 67038.138 ns
         hf_count   001000   (the async counter right now)
         nd         000fff   n2         000fff
         gray_bin   000fff   gray_naked 000fff
```

VCD for that window: **18 KB against 5.7 MB** for the full run — 316× smaller,
and it opens already centred on the event. That is what buys the full-hierarchy
dump: the window is small enough to afford it.

Other triggers, via testbench parameters (`TRIG_MODE`): `1` first tear, `2`
first DUT UART reply, `3` an exact `hf_count` value. Mode 3 uses a hierarchical
reference and so is behavioral-only — it is compiled out unless `HIER_OK` is
defined, which `make smoke` does and the timing flow deliberately does not.

```bash
make smoke TBP='-Ptb_cdc_corruption.TRIG_MODE=3 -Ptb_cdc_corruption.TRIG_COUNT=4096 -Ptb_cdc_corruption.TRIG_STOP_NS=100'
```

Stopping shortly after the trigger (`TRIG_STOP_NS`) matters more than it sounds
under SDF annotation: there is no reason to simulate another 30 µs at ~1000×
slowdown once you have the event.

## Seeing a real tear without Vivado

`make trap` needs the timing netlist, which needs the instance. `make trap-skew`
gets you an actual torn read on the laptop, in about two seconds:

```bash
make trap-skew
```

Same two-pass structure. Measured, from a clean tree:

```
pass 1 — locating the first tear (no waveform)
TRIGGER  first tear at 2345.000 ns
         led[3:1] = 011  (gray_naked, naive_2ff, naive_direct)
         tears  nd=1  n2=1  gray=0  gnaked=0

pass 2 — first tear at 2345.000 ns; dumping [2145.000, 2545.000] ns, full hierarchy
waveform: build/cdc_corruption_a7.vcd  (400 ns window)   27,570 bytes
```

And the event itself:

```
2325 ns   nd = 00008f   step +1
2335 ns   nd = 000080   step -15   <-- torn
2345 ns   nd = 000090   step +16
```

The counter went `0x8f → 0x90`. It was never `0x80` — not before, not after.
`0x8f → 0x90` is a four-bit carry, `1000 1111 → 1001 0000`: bits 0–3 clear and
bit 4 sets, nominally at the same instant. This capture caught bits 0–3 already
cleared with bit 4 not yet arrived. Every bit is individually correct at some
instant; the assembled word is correct at none. `tear_nd` and `tear_n2` both
fire, `tear_gray` stays zero — the hardware result, reproduced.

### How, given that behavioral simulation cannot tear

It can't, and that claim stands. `SIM_SKEW` (in `top_a7.v`, compiled in only for
this target) injects **per-bit routing skew** — roughly 2 ns spread across the
24-bit bus feeding the crystal-domain reads.

That is not a cheat, it is the dominant failure mechanism. These paths fail
mostly from skew, not metastability: 24 bits leave one domain on 24 different
routes and arrive at 24 different times, so a sample near a transition assembles
a word from two different counts. **That is precisely why per-bit 2-flop
synchronization does not help** — it fixes each bit's metastability and leaves
the bits disagreeing about which count they came from. Skew is deterministic,
and a behavioral simulator models it perfectly.

It is also not arbitrary: those crossings are *unconstrained by design* in the
XDC, which is exactly what licenses a router to skew them.

**The rate this produces is meaningless.** It is a property of the delay numbers
in `top_a7.v`, not of silicon, and there is a warning in the source saying so.
Metastability is not modelled here at all. The mechanism is real; the magnitude
needs post-implementation timing simulation or the board. `cdc_capture` is fed
the unskewed bus, because it samples in its own domain — skewing that would have
been wrong.

For the board, the same idea becomes RTL rather than testbench — a trap-on-tear
register that latches the torn value, the coherent value and a timestamp on the
first mismatch, readable over UART. That is listed as the open enhancement on
the iCE40 project and is the only version that works where there is no simulator
at all.

Two knobs in `run.tcl` matter. `SIM_CPB` sets the simulation link speed to
6.25 Mbaud — 115200 baud costs ~6 ms of simulated time for a register sweep,
which is fine behaviorally and intolerable under SDF. `OBS_US_TIMING` is short
on purpose: annotated timing sim is roughly 1000× slower than behavioral, so
the testbench's deliberate phase walk, not elapsed time, is what finds the
aperture.

## What the audit checks

`report_cdc.tcl` is a regression test, not a document:

- **`report_cdc`** — tallies findings by severity and **fails the run if there
  are zero Critical findings**, because a clean report on a design with three
  planted bugs means the tool or the netlist is broken, not that the design is
  safe.
- **`report_clock_interaction`** — read alongside the CDC report. A clock pair
  marked *Asynchronous Groups* here and *Critical* there is a crossing someone
  waived in the timing report without fixing in the RTL. That pairing is the
  whole audit.
- **`report_synchronizer_mtbf`** — **unsupported on `7a35ti`.** Vivado returns
  `[Vivado 12-3426] Metastability report is not supported for device 7a35ti`, so
  this flow produces no MTBF numbers at all. The `catch` in `report_cdc.tcl`
  handles it. On a device that does support it, it reports only on
  `ASYNC_REG`-marked flops — which is one reason the flops are marked.
- **`check_timing`** and **`report_exceptions -ignored`** — unconstrained
  endpoints, and `set_false_path`/`set_max_delay` statements that match nothing
  and are quietly doing zero while everyone assumes they are load-bearing.

The XDC is written as the audit artifact: every crossing is either constrained
deliberately or left unconstrained deliberately, with the reason in the comment,
and `report_cdc` has to agree with the comments.

Two things worth internalizing from it:

**`set_clock_groups -asynchronous` is the most-abused constraint in the
industry.** It silences the timing report on these crossings and changes nothing
about the hardware. The three broken paths remain broken. It buys a readable
timing report and nothing else.

**It does not hide the crossings from `report_cdc`.** Timing exceptions suppress
the timing engine; the CDC engine walks the netlist structurally and finds them
anyway. That asymmetry is the entire argument for running both — and the reason
a green timing summary is not evidence of a safe design.

## Files

| File | Purpose |
|------|---------|
| `top_a7.v` | Artix-7 top: async clock source, unchanged RTL underneath |
| `cdc_corruption_a7.xdc` | Arty A7-35T pins, clocks, CDC constraints + waivers |
| `tb_cdc_corruption.sv` | XSim testbench — pin-level, so one TB drives behavioral, post-synth and timing sim |
| `run.tcl` | non-project flow: behav / synth / cdc / impl / timing / trap |
| `report_cdc.tcl` | the CDC + constraint audit, with the known-answer check |
| `unisim_stub.v` | stub `BUFG`/`STARTUPE2` for the laptop smoke test only |
| `Makefile` | one word per stage |
| [`../SETUP.md`](../SETUP.md) | EC2 instance sizing, Vivado install, cost, first-run sequence |
| [`../docs/two-toolchains.md`](../docs/two-toolchains.md) | The cross-flow comparison — what each toolchain can and cannot see |

Target is the Arty A7-35T (`xc7a35ticsg324-1L`); the part and the pin section of
the XDC are the only board-specific lines.

## Measured — Vivado 2025.2 on EC2, xc7a35ticsg324-1L

> For the cross-flow comparison — what the open iCE40 toolchain and Vivado can
> each see, the AWS architecture, and the methodology failures found along the way
> — see [`docs/two-toolchains.md`](../docs/two-toolchains.md). This section is the
> stage-by-stage record; that document is the argument.


First real run of the vendor flow, 2026-08-10.

### CDC audit — known-answer check PASS

```
CDC severity tally:  Critical=72  Warning=25  Info=2

CDC-1   Critical  24  1-bit unknown CDC circuitry             <- gray, NO synchronizer
CDC-11  Critical  48  Fan-out from launch flop to dest clock  <- naive direct + naive 2FF
CDC-15  Warning   24  Clock enable controlled CDC structure
CDC-6   Warning    1  Multi-bit synchronized with ASYNC_REG   <- gray + 2FF   (correct)
CDC-3   Info       2  1-bit synchronized with ASYNC_REG       <- handshake    (correct)
```

Three planted bugs flagged Critical; both correct references recognised as
synchronized. The tool is calibrated.

### The contrast that is the whole point

`clock_interaction.rpt`, post-route, same run:

```
clk_async -> sys_clk     121 endpoints   Ignored   Asynchronous Groups
sys_clk   -> clk_async     1 endpoint    Ignored   Asynchronous Groups
sys_clk   -> sys_clk      WNS 1.610      Clean     Timed
clk_async -> clk_async    WNS 10.081     Clean     Timed
```

**Every timed clock pair is Clean. 122 endpoints are Ignored. `report_cdc`
returns 72 Critical findings on those same ignored paths.** The timing summary is
not lying — it is answering a different question, because `set_clock_groups
-asynchronous` excused those paths from analysis and excusing them changed
nothing about the silicon. Put the two reports side by side and the case makes
itself.

### Post-implementation timing simulation

47,798 `$setuphold` violations from the SIMPRIM `FDRE` models, distributed
exactly as the theory predicts:

| capture flop | violations | |
|---|---|---|
| `u_c/nd_r_reg` | 17,170 | naive direct — stage 1, result used directly |
| `u_c/n2_meta_reg` | 15,597 | naive 2FF — stage 1 |
| `u_c/gray_meta_reg` | 8,442 | gray + 2FF — stage 1 |
| `u_c/gray_naked_reg` | 6,589 | gray, no synchronizer |
| `u_c/gray_sync_reg` | **0** | gray + 2FF — **stage 2** |
| `u_hs/stamp_q_reg`, `u_hs/data_reg` | **0** | handshake |

Violations on stage 1 of the *correct* gray path are not a defect — absorbing
metastability is precisely what stage 1 exists to do. Stage 2 takes none, and
neither does the handshake; the naive paths have no stage 2 at all. That is a
real structural result and it is what the violation census is good for.

**But do not over-read it.** In the trapped waveform the correctly synchronized
`gray_bin` output reads `xxxxxx`: X from the stage-1 violation propagates
straight through stage 2, because the simulator cannot model metastability
*resolving*. Timing simulation is **X-pessimistic across every synchronizer** —
it renders working and broken CDC identically at the data level. It tells you
*which flops are being hit*, not *which designs survive*. Structure comes from
`report_cdc`; behaviour comes from silicon.

**Known limitation:** that same X propagation hangs the UART readout under full
annotation, so there is no tear-count table from this run and the *rate* has to
come from hardware. Run wall time was 14 minutes for 30 us simulated.

### Implementation

WNS **+1.470 ns**, 36 seconds wall, peak memory **2982 MB** — against AMD's
published 3 GB figure for this part. The sizing in [SETUP.md](../SETUP.md) held
exactly; the widely repeated "8 GB for Artix-7" would have been 2.7x oversized.

### Four ways this flow lied before it told the truth

Every one of these produced a run that looked healthy:

1. **XDC is not Tcl.** `if` is rejected as a CRITICAL WARNING, not an error, so
   the block is skipped and the run continues. The conditional creating
   `clk_async` never executed; the design synthesized with one clock and
   `report_cdc` truthfully found zero crossings in a design made of crossings.
2. **`report_cdc -return_string` needs `-details`.** Without it you get the
   per-clock-pair summary, which carries no `CDC-nn` rule ID, so ID-based parsing
   matches nothing. The gate reported "zero Critical findings" against a report
   listing 72.
3. **`-sdfmax` cannot match escaped instance names.** Post-route names contain
   brackets (`hf_count[0]_i_1`), and XSim skipped 1486 of 1487 instances one
   `[XSIM 43-3477]` warning at a time — while still printing `[XSIM 43-3452] SDF
   backannotation was successful` for the file. A "timing simulation" with no
   timing. `write_verilog -sdf_anno true` fixes it: skips went 1486 -> 0.
4. **Sticky trigger bits.** `led[3:1]` latch "counter non-zero" and never clear,
   so "first tear" meant "any tear ever, including during GSR" — and `gray_naked`
   always scores one at reset. The trap fired on a reset artifact at exactly
   t=1000 ns. Arming late overcorrected and masked the real events. The working
   form snapshots what is already dirty and fires on the first bit to go dirty
   *after* that: genuine first tear at **1014.143 ns** on `naive_direct`.

Numbers 2 and 3 are the instructive ones. Both were tools reporting **success at
one level while failing completely at another**, and both would have produced a
confident, wrong writeup. This is the argument for known-answer testing stated as
plainly as it can be: the only reason any of these were caught is that the
expected answer was known in advance and the check refused to pass without it.

## Status

**Run under Vivado 2025.2 on EC2, 2026-08-10.** `synth`, `cdc`, `impl`,
`timing` and `trap` have all executed against real silicon models — see
[Measured](#measured--vivado-20252-on-ec2-xc7a35ticsg324-1l) above.
[SETUP.md](../SETUP.md) has the instance sizing, install, cost and first-run
sequence.

**The laptop path also passes**, and is still the fast loop. `make smoke`: the
design elaborates, the UART model and all ten registers work, all five reads
return coherent values, all tear counters read zero — the correct behavioral
result, and the reason this port exists. `make trap-skew`: two-pass trigger,
first tear at 2345 ns, 400 ns window dumped at 27 KB instead of 5.7 MB.

Two places bit on first contact and are commented where they will bite again on
a different Vivado version:

- the cell-name regexes in the XDC (`ASYNC_REG`, `set_max_delay`,
  `set_bus_skew`) and the `DONT_TOUCH` patterns in `run.tcl` — synthesized names
  depend on the Vivado version. `report_cdc.tcl`'s known-answer check is
  designed to fail loudly if they miss, rather than emit a clean report.
- `-generic_top` reaching the testbench parameters, and `-sdfmax` resolving
  `/tb_cdc_corruption/dut`.
