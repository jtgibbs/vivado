# Provenance of `rtl/`

These five files are **byte-identical copies**, not adaptations. The entire claim
of this project is that Vivado is being handed *unchanged* RTL — the same source
that ran on real iCE40 silicon and produced the tear rates quoted in the
[project README](../README.md). A silently diverged copy would turn that claim
into a lie, so the provenance is recorded rather than asserted.

## Source

Private repository `jtgibbs/icebreaker`, commit
**`7322294215bb21c0a90af3cb4ba82c205d0abd44`** (`main`).

| File | Path in source repo |
|---|---|
| `corrupt.v` | `fpga/cdc_corruption/corrupt.v` |
| `readout.v` | `fpga/cdc_corruption/readout.v` |
| `cdc_capture.v` | `fpga/counter_readout/cdc_capture.v` |
| `uart_rx.v` | `fpga/uart_echo/uart_rx.v` |
| `uart_tx.v` | `fpga/uart_echo/uart_tx.v` |

## SHA-256 (first 16 hex digits)

| File | Digest |
|---|---|
| `corrupt.v` | `b4c0e8d76f9fe33f` |
| `readout.v` | `5b52797d23317ebf` |
| `cdc_capture.v` | `f0aa751155fd535d` |
| `uart_rx.v` | `fa16c40a590c7e95` |
| `uart_tx.v` | `6c8c5da6b70bbebc` |

Verify at any time, with no access to the source repo:

```bash
shasum -a 256 cdc_corruption_a7/rtl/*.v
```

## Re-checking against the source

If you have the iCE40 repo checked out:

```bash
make check-sync ICEBREAKER=/path/to/icebreaker
```

`make sync` re-copies. Both are conveniences — the source repo is **not** a build
dependency, and its absence is the normal state here and on the EC2 instance.

## Why copies and not a submodule

This directory has to `rsync` to a remote instance as one self-contained tree,
with no repo, no network and nothing to resolve on the far end. A submodule would
reintroduce exactly the dependency the copies exist to remove — and would make a
private repo a hard requirement for building a public one.

The cost of copying is drift. The digests above are what make drift detectable
without trusting anyone's memory.
