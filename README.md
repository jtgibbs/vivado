# vivado

Vivado work on AWS EC2 — the vendor analysis flow, targeting Artix-7.

Static timing analysis, timing exceptions, CDC reporting, post-implementation
timing simulation. None of it exists in the open FPGA toolchain, and all of it is
what a constraint audit actually consists of.

## Why a separate repo

The phenomena and the analysis are different skills, and they need different
tools.

|  | proves | needs |
|---|---|---|
| open toolchain + real board | the **phenomena** — does it actually tear | silicon |
| **Vivado / STA** ← this repo | the **analysis** — would a competent toolchain have caught it | a vendor flow |

The board answers "does it tear." Only a vendor flow answers "would this have
been caught before tape-out" — which is the question a client pays for.
`report_cdc`, `report_clock_interaction`, `report_exceptions -ignored`,
`set_bus_skew`, timing exceptions, SDF-annotated simulation: the open tools have
none of them.

The CDC work itself is finished and lives elsewhere — measured on real iCE40
silicon, tear rates and all. This repo is not more of that. It is about learning
and proving the toolchain, and the first design run through it was chosen
precisely because its answers are already known.

## Contents

| | |
|---|---|
| [`cdc_corruption_a7/`](cdc_corruption_a7/) | 🔧 First payload. One async counter read five ways — two correct, three deliberately wrong — through a full non-project Vivado flow: XSim behavioral + post-implementation timing simulation, `report_cdc` audit, trap-on-event waveform capture. |
| [`SETUP.md`](SETUP.md) | EC2 instance sizing, Vivado install, licensing, cost, teardown. Sized from AMD's own memory table rather than folk wisdom; the answer is smaller than most people expect. |

Planned:

- **Reduced-settling-window metastability rig.** Harvesting real metastability
  events needs a deliberately shrunken settling window — an MMCM with dynamic
  phase shift. At 12 MHz an iCE40 flop gets 83 ns to resolve (t_r/τ ≈ 250), so
  zero events is the *correct* result there and no amount of patience fixes it.
  This needs the vendor clocking primitives.
- **Constraint-audit writeup.** Take a design with plausible-looking constraints,
  show what the reports actually prove versus what the author assumed, and
  quantify the gap.

## Calibrating the tool, not the engineer

`cdc_corruption_a7` is a **known-answer test**: three deliberately broken
crossings, two correct references, and hardware-measured failure rates in hand
before Vivado ever sees it.

That is the whole reason it goes first. A CDC report on unfamiliar code tells you
what the checker *noticed* — it can never tell you what it *missed*. Run the tool
against a design whose bugs you planted and you learn where its blind spots are,
before trusting it on something that matters. `report_cdc.tcl` fails the run on
zero Critical findings for exactly that reason: on this design, a clean report
means the tool is broken, not the design.

## Status

**Nothing has run under Vivado yet.** There is no Vivado on the development
machine — that is what the EC2 work in `SETUP.md` is for.

`cdc_corruption_a7` is verified as far as it can be without it: the design
elaborates, simulates, and catches a real torn read under Icarus with stub
primitives. Every Vivado stage is written and syntax-checked and **unrun**. Each
project here states plainly which of its claims are measured and which are only
written.

## A note on numbers

Where a failure rate appears, it says where it came from. Rates measured on
hardware are labelled as such. Rates produced by injected simulation models are
labelled **mechanism-only and quantitatively meaningless** — the mechanism is
real, the magnitude is a property of the injected delays.

Conflating those two is the exact error this kind of work exists to catch in
other people's designs.
