# EC2 + Vivado setup

Everything in this project except `make smoke` and `make trap-skew` needs Vivado,
which does not run on Apple Silicon macOS — it is x86-64 Linux/Windows only, and
emulating it locally on an M4 would be slower than the network round trip. So:
a Linux EC2 instance, Vivado ML Standard, DCV when a GUI is actually needed.

**This has all been run.** The instance was provisioned and Vivado installed on
2026-08-10; `synth`, `cdc`, `impl`, `timing` and `trap` all executed against real
silicon models. Results are in the [project README](cdc_corruption_a7/README.md).
What follows is the sizing reasoning and the install sequence as actually performed,
with the figures that turned out to matter.

---

## The sizing surprise

The instinct is to buy a big-memory instance. **For this device you do not need
one.** AMD's own memory table:

| Device | Typical | Peak |
|---|---|---|
| XC7A15T … XC7A100T | 2 GB | **3 GB** |
| XC7A200T | 2.5 GB | 3.5 GB |

3 GB peak. That is Vivado's requirement for the whole flow on an `xc7a35t` — and
this design is a 24-bit counter and a UART, not a soft CPU. Secondary sources
repeat "8 GB for Artix-7"; that is folk wisdom, and following it would buy
several times the memory this needs.

The real constraints are different:

- **Disk.** Artix-7 alone is a **13.85 GB download, 48.64 GB installed**. That is
  the binding number, and it is what accrues cost while the instance is *stopped*.
- **Single-thread speed.** Synthesis and much of place-and-route are effectively
  single-threaded, and SDF-annotated timing simulation — the whole point of this
  project — is entirely so. Clock rate beats core count. Compute-optimized (`c7i`,
  3.2 GHz Sapphire Rapids) is the right family, not memory-optimized.

## Recommendation

**`c7i.xlarge`** — 4 vCPU, 8 GiB, **$0.179/hr** on-demand in `us-east-1`.

8 GiB is still ~2.5× Vivado's peak for this part, leaving room for the OS and a
DCV desktop. Step up to `c7i.2xlarge` (8 vCPU, 16 GiB, $0.357/hr) only if
place-and-route wall time actually annoys you — on a design this small it will
not. `m7i` costs more for memory you will not use.

| | vCPU | RAM | On-demand | Spot |
|---|---|---|---|---|
| **c7i.xlarge** ← | 4 | 8 GiB | $0.179/hr | $0.076/hr |
| c7i.2xlarge | 8 | 16 GiB | $0.357/hr | $0.154/hr |

**Storage: 100 GB gp3.** ~50 GB Vivado + OS + projects + room for timing
netlists, which are large. gp3's baseline 3,000 IOPS / 125 MB/s is included, so
do not provision extra.

**AMI: plain Ubuntu 22.04 or 24.04 LTS**, not the AWS FPGA Developer AMI. The
FPGA AMI is built for F1/F2 instances and its Vivado entitlement is tied to
running on one; it would drag you onto a far more expensive instance family for
no benefit. This target is a 7-series part supported by the free edition.

## Cost

The instance is not the expensive part — **the volume is**, because it bills
whether or not the instance is running.

| | |
|---|---|
| 100 GB gp3, always | **$8.00/mo** — the floor, even fully stopped |
| c7i.xlarge, 10 hr/week | ~$7.75/wk → **~$31/mo** |
| **Realistic total** | **~$25–40/mo** at a few hours a week |

Inbound data transfer is free, so the 13.85 GB Vivado download costs nothing.

Two things that actually cause surprise bills: leaving a DCV session running
overnight (the instance does not idle-stop by itself), and forgetting an
Elastic IP — an EIP not attached to a *running* instance bills hourly. If you
allocate one, release it when you tear down.

Spot at $0.076/hr is tempting and mostly fine here — the work is
checkpoint-and-resume by nature — but a two-minute interruption notice during a
40-minute install is a bad trade. Install on-demand; consider spot afterwards.

## Licensing — install 2025.x, not 2026.1

**Pin the version.** Install **Vivado ML Standard 2025.x**. This is a deliberate
choice, not inertia, and it is the single biggest risk to this whole plan.

Through 2025.x, Vivado ML Standard is free, needs no licence file, and covers
Spartan-7, Artix-7, selected Zynq-7000 and some Kintex-7 — `xc7a35t` is in. Not a
time-limited trial.

**From 2026.1 (June 2026) AMD replaced that with a five-tier model** — BASIC
(free, *annual renewal*), CORE (~$1,200–1,800/yr), PRO (~$2,400–3,000/yr),
ENTERPRISE (~$4,395–5,495 perpetual), GOLD (~$10–15K). Widespread reporting says
**the free BASIC tier excludes Linux**, with native Linux use landing in CORE.

Confidence, stated honestly: that Linux exclusion is reported by multiple
outlets, but as of May 2026 AMD had **not fully clarified it**, and sources
contradict each other on whether BASIC covers Linux at all. Do not plan around
either reading without confirming it against AMD directly.

This entire flow is Linux — the whole point of the instance. So:

- **2025.x removes the question.** The change applies from 2026.1 forward.
  `run.tcl` is version-agnostic and nothing here needs a 2026.1 feature.
- The second-order risk is worse than the price: BASIC requires **annual
  renewal**, and reporting suggests designs can become unusable if you lapse.
  For a portfolio repo meant to stay reproducible for years, a licence that
  expires is a defect.
- Revisit only when AMD has published unambiguous Linux terms, or when something
  here actually needs a newer release. Neither is true today.

If you do end up needing 2026.1+ on Linux, budget for CORE and price it before
launching the instance, not after.

## Sequence

1. Launch `c7i.xlarge`, Ubuntu LTS, 100 GB gp3, key pair, security group
   allowing SSH from your IP only — **not** `0.0.0.0/0`.
2. Install Vivado ML Standard **2025.x** (see Licensing — do not take 2026.1),
   selecting **only** Artix-7 under Devices → Production Devices → 7 Series.
   Selecting everything is ~200 GB and buys nothing.
3. `rsync -a fpga/cdc_corruption_a7/ instance:cdc_corruption_a7/` — the directory
   is self-contained by design, `rtl/` holds real copies rather than `../`
   references. Nothing else from the repo is needed.
4. `source /tools/Xilinx/Vivado/<ver>/settings64.sh`, then `make synth`. That is
   the cheapest stage that proves the flow: it exercises source reading, the XDC,
   synthesis, and `report_cdc.tcl`'s known-answer check. Do not run `make all`
   first — if the cell-name patterns are wrong you want to know before a
   place-and-route.
5. Then `make impl`, then `make timing`, then `make trap`.
6. DCV only when you want the GUI (`make gui` opens the routed checkpoint).
   Batch stages need no desktop at all and should be run over plain SSH.
7. **Stop** the instance when done — stop, not terminate. Stopping keeps the
   volume and the install; terminating destroys the ~50 GB Vivado install you
   waited on.

## What actually went wrong on first contact

This section used to predict three failures. Two of the three predictions were
wrong, and the ones that did bite were not on the list — which is itself the
lesson, so the record stays rather than being quietly rewritten.

**Predicted and did NOT happen:** cell-name patterns all matched on 2025.2
(`ASYNC_REG` on 52 cells, both safe buses bounded 24→24, `DONT_TOUCH` 24 cells per
path). `CLOCK_DEDICATED_ROUTE` was a non-event — placement never complained.

**Predicted and DID happen, differently than expected:** `-sdfmax` failed, but not
over `/tb_cdc_corruption/dut` resolving. It failed on **escaped instance names** —
post-route cells like `hf_count[0]_i_1` contain brackets, and XSim skipped **1486
of 1487** instances one warning at a time while still printing
`[XSIM 43-3452] SDF backannotation was successful` for the file. A timing simulation
with no timing. Fixed with `write_verilog -sdf_anno true`, which lets the netlist
self-annotate: skips went 1486 → 0.

**Not predicted at all, and the one that cost the most:**

- **XDC is not Tcl.** Vivado's constraint reader is a restricted command set. `if`
  is rejected as a *CRITICAL WARNING, not an error*, so the block is skipped and the
  run continues looking healthy. The conditional creating `clk_async` never executed,
  the design synthesized with a single clock, and `report_cdc` truthfully reported
  zero crossings in a design made entirely of crossings. Anything needing a guard now
  lives in `run.tcl`, which is real Tcl.
- **`report_cdc -return_string` needs `-details`.** Without it you get the
  per-clock-pair summary, which carries no `CDC-nn` rule ID, so ID-based parsing
  matches nothing. The audit gate reported "zero Critical findings" against a report
  listing 72.
- **`report_synchronizer_mtbf` is unsupported on `7a35ti`** — `[Vivado 12-3426]`.
  No MTBF numbers from this flow at all, on any device in this family.

The two that matter are the middle pair: both were **tools reporting success at one
level while failing completely at another**, and both would have produced a
confident, wrong writeup. The only reason either was caught is that the expected
answer was known in advance and the gate refused to pass without it.

## Sources

- [AMD Vivado memory recommendations](https://docs.google.com/spreadsheets/d/1dSPo0sMx14Y513ix39iYsVnmUvQM_2pFeZpllw-Bi28/edit) (AMD's published table, linked from [UG973](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/System-Memory-Recommendations))
- [Vivado edition / device support](https://pcbsync.com/xilinx-vivado-editions/)
- 2026.1 licensing change: [AMD licensing options](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html) · [analysis](https://bard0.com/insights/vivado-2026-1-licensing.html) · [Tom's Hardware on the Linux exclusion](https://www.tomshardware.com/software/linux/amd-leaves-linux-fpga-users-in-the-lurch-with-controversial-vivado-licensing-update-new-tier-model-restricts-future-free-versions-to-windows)
- [Install size by device selection](https://adaptivesupport.amd.com/s/question/0D54U00005cVQZbSAO/vivado-20221-ml-standard-without-any-device-support-requires-118gb-disk-space-is-this-right?language=en_US)
- [c7i.xlarge](https://instances.vantage.sh/aws/ec2/c7i.xlarge) · [c7i.2xlarge](https://instances.vantage.sh/aws/ec2/c7i.2xlarge) pricing
- [EBS pricing](https://aws.amazon.com/ebs/pricing)
- [AWS DCV setup for Vivado](https://github.com/aws-samples/aws-remote-desktop-for-eda)
