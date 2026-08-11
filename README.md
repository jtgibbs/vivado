# vivado

Vivado work on AWS EC2 — the vendor analysis flow, targeting Artix-7.

Timing exceptions, clock-interaction reporting, CDC analysis, post-implementation
timing simulation — the machinery a constraint audit is actually made of.

The open toolchain is not without timing analysis: `nextpnr` does genuine
per-clock STA and will tell you both domains pass. What it has no way to express
or report is the *relationship* between those domains, which is where the
interesting failures live.

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
| [`docs/two-toolchains.md`](docs/two-toolchains.md) | What the open flow and the vendor flow can each see, run against byte-identical RTL — tool inventories, the AWS architecture, the same failure captured in both, and four cases of a tool reporting success while failing. |

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

**Running on EC2 since 2026-08-10.** Vivado ML Standard 2025.2 on a `c7i.xlarge`,
targeting `xc7a35ticsg324-1L`. Every stage — synthesis, CDC audit, place & route,
post-implementation timing simulation, trap-on-event — has executed against real
silicon models.

Headline results, with the full record in the
[project README](cdc_corruption_a7/README.md) and the argument in
[`docs/two-toolchains.md`](docs/two-toolchains.md):

- **`report_cdc` known-answer check: PASS.** 72 Critical / 25 Warning / 2 Info.
  All three planted bugs flagged; both correct references recognised as
  synchronized.
- **The contrast worth having.** Post-route, every timed clock pair reads *Clean*
  while 122 endpoints read *Ignored* — on the same design where `report_cdc`
  returns 72 Critical findings.
- **Implementation:** WNS +1.470 ns, 36 s wall, 2982 MB peak against AMD's
  published 3 GB for this part.
- **Timing simulation:** 47,798 `$setuphold` violations, landing on stage 1 of
  every path that samples the async bus and on neither the gray synchronizer's
  stage 2 nor the handshake.

Still open: nothing here has been on a board, there are no MTBF numbers
(`report_synchronizer_mtbf` is unsupported on the 7a35ti), and timing simulation
cannot confirm a synchronizer *works* — X-pessimism renders the correct path
unknown. Each project states plainly which of its claims are measured and which
are only written.

## A note on numbers

Where a failure rate appears, it says where it came from. Rates measured on
hardware are labelled as such. Rates produced by injected simulation models are
labelled **mechanism-only and quantitatively meaningless** — the mechanism is
real, the magnitude is a property of the injected delays. Both kinds appear in
this repo; the labels are what keep them apart.
