# EC2 + Vivado setup

Everything in this project except `make smoke` and `make trap-skew` needs Vivado,
which does not run on Apple Silicon macOS — it is x86-64 Linux/Windows only, and
emulating it locally on an M4 would be slower than the network round trip. So:
a Linux EC2 instance, Vivado ML Standard, DCV when a GUI is actually needed.

Nothing here has been executed yet. These are the sized, sourced decisions, not
a transcript of a working install.

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

## Licensing

**Vivado ML Standard is free and needs no licence file.** It covers Spartan-7,
Artix-7, selected Zynq-7000 and some Kintex-7 — `xc7a35t` is in. Requires an AMD
account to download. Not a time-limited trial.

## Sequence

1. Launch `c7i.xlarge`, Ubuntu LTS, 100 GB gp3, key pair, security group
   allowing SSH from your IP only — **not** `0.0.0.0/0`.
2. Install Vivado ML Standard, selecting **only** Artix-7 under
   Devices → Production Devices → 7 Series. Selecting everything is ~200 GB and
   buys nothing.
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

## Expected first-contact failures

Called out where they will bite, but worth knowing in advance:

- **Cell-name patterns.** The `ASYNC_REG` / `set_max_delay` / `set_bus_skew`
  selectors in the XDC and the `DONT_TOUCH` patterns in `run.tcl` depend on how
  the installed Vivado version names synthesized cells. `report_cdc.tcl` is built
  to fail loudly on zero Critical findings rather than emit a falsely clean
  report, so a miss announces itself.
- **`-generic_top` and `-sdfmax`.** Parameter override reaching the testbench,
  and `/tb_cdc_corruption/dut` resolving for SDF annotation.
- **`CLOCK_DEDICATED_ROUTE`.** `ck_ja0` is not a clock-capable pin; the waiver is
  in the XDC with its justification. If the version disagrees about the net name,
  placement fails with a clear message.

## Sources

- [AMD Vivado memory recommendations](https://docs.google.com/spreadsheets/d/1dSPo0sMx14Y513ix39iYsVnmUvQM_2pFeZpllw-Bi28/edit) (AMD's published table, linked from [UG973](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/System-Memory-Recommendations))
- [Vivado edition / device support](https://pcbsync.com/xilinx-vivado-editions/)
- [Install size by device selection](https://adaptivesupport.amd.com/s/question/0D54U00005cVQZbSAO/vivado-20221-ml-standard-without-any-device-support-requires-118gb-disk-space-is-this-right?language=en_US)
- [c7i.xlarge](https://instances.vantage.sh/aws/ec2/c7i.xlarge) · [c7i.2xlarge](https://instances.vantage.sh/aws/ec2/c7i.2xlarge) pricing
- [EBS pricing](https://aws.amazon.com/ebs/pricing)
- [AWS DCV setup for Vivado](https://github.com/aws-samples/aws-remote-desktop-for-eda)
