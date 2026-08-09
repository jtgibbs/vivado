# fpga-cdc-audit

Clock-domain-crossing and static timing analysis work in a vendor toolchain —
Vivado on AWS EC2, targeting Artix-7.

The premise: **a CDC report tells you what the checker noticed, never what it
missed.** So the tools get calibrated against designs whose answers are already
known — bugs planted deliberately, correct references alongside them, failure
rates measured on real silicon beforehand. Only then is a report on unfamiliar
code worth anything.

## Why this exists separately from the phenomena

Two different skills, and they need different tools:

|  | proves | needs |
|---|---|---|
| open toolchain + real board | the **phenomena** — does it actually tear | silicon |
| Vivado / STA | the **analysis** — would a competent toolchain have caught it | a vendor flow |

The board answers "does it tear." Only a vendor flow answers "would this have
been caught before tape-out" — which is the question a client actually pays for.
`report_cdc`, `report_clock_interaction`, `report_exceptions -ignored`,
`set_bus_skew`, timing exceptions, post-implementation timing simulation: none
of it exists in the open iCE40 tools, and all of it is the deliverable in a
constraint audit.

## Contents

| | |
|---|---|
| [`cdc_corruption_a7/`](cdc_corruption_a7/) | 🔧 One async counter read five ways — two correct, three deliberately wrong — through a full non-project Vivado flow: XSim behavioral + post-implementation timing simulation, `report_cdc` audit, trap-on-event waveform capture. The known-answer test. |
| [`SETUP.md`](SETUP.md) | EC2 instance sizing, Vivado install, licensing, cost and teardown. Sized from AMD's own memory table rather than folk wisdom, and the conclusion is smaller than most people expect. |

Planned:

- **Reduced-settling-window metastability rig.** Harvesting real metastability
  events needs a deliberately shrunken settling window — an MMCM with dynamic
  phase shift. On a 12 MHz iCE40 a flop gets 83 ns to resolve (t_r/τ ≈ 250), so
  zero events is the *correct* result there and no amount of patience fixes it.
- **Constraint-audit writeup.** Take a design with plausible-looking constraints,
  show what the reports actually prove versus what the author assumed, and
  quantify the gap.

## Status

`cdc_corruption_a7` is verified as far as it can be without Vivado: it
elaborates, simulates, and catches a real torn read under Icarus with stub
primitives. **Every Vivado stage is written but unrun** — see the project README
for exactly what that means. Honest status beats an optimistic one; each project
here states which of its claims are measured and which are merely written.

## A note on numbers

Where a failure rate is quoted, it says where it came from. Rates measured on
hardware are labelled as such. Rates produced by injected simulation models are
labelled as **mechanism-only and quantitatively meaningless** — the mechanism is
real, the magnitude is a property of the injected delays. Conflating those two is
the exact error this repo exists to catch in other people's work.
