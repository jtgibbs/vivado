# cdc_corruption_a7.xdc — Arty A7-35T pins, clocks, and CDC constraints.
#
# This file is half pinout and half the actual deliverable. The CDC section is
# written the way a constraint audit should read: every asynchronous crossing in
# the design is either constrained deliberately or left unconstrained
# deliberately, and the comment says which and why. `report_cdc` then has to
# agree with the comments. Where it disagrees, one of the two is lying.
#
# The design contains, by construction, five crossings of the same bus — two
# safe, three broken. A clean CDC report here would mean the tool is wrong.

# ─────────────────────────────────────────────────────────────────────────────
# Pins — Digilent Arty A7-35T (xc7a35ticsg324-1L)
# ─────────────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]

# PMOD JA[0] — external asynchronous clock input (ASYNC_SRC = "EXT").
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports ck_ja0]

# USB-UART bridge (FT2232 channel). Names are from the FPGA's point of view
# reversed relative to the schematic net names, which is a classic bring-up trap:
# uart_txd_in is the HOST's transmit, i.e. our receive.
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]

set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ─────────────────────────────────────────────────────────────────────────────
# Clocks
# ─────────────────────────────────────────────────────────────────────────────
create_clock -name sys_clk -period 10.000 [get_ports CLK100MHZ]

# ── NOTE: XDC IS NOT TCL ──────────────────────────────────────────────────────
# Vivado reads .xdc with a *restricted* command set. `if`, `foreach` and friends
# are rejected with "[Designutils 20-1307] Command 'if' is not supported in the
# xdc constraint file" — a CRITICAL WARNING, not an error, so the block is
# silently skipped and the run continues looking healthy.
#
# That is exactly how this file failed the first time it met a real Vivado: the
# conditional that created clk_async never executed, the design had one clock,
# and report_cdc truthfully reported zero crossings on a design built entirely
# out of crossings. The known-answer check caught it; a "looks clean" reading
# would not have.
#
# So: this file is now strictly declarative. Anything needing control flow lives
# in run.tcl, which is full Tcl.
# ──────────────────────────────────────────────────────────────────────────────

# The asynchronous domain (ASYNC_SRC = "EXT", the default — testbench-driven).
# 65 MHz nominal, matching the internal ring oscillator this stands in for.
# Constrain it FASTER than the testbench drives it: the async domain's own
# internal timing must close with margin, or a failure inside that domain would
# masquerade as a CDC failure and the whole measurement is worthless.
create_clock -name clk_async -period 14.000 [get_ports ck_ja0]

# ck_ja0 is a general-purpose I/O, not a clock-capable pin, so it cannot reach a
# BUFG on the dedicated clock route. This waiver is safe HERE and only here: the
# async domain is a free-running counter whose absolute skew to anything else is
# irrelevant by definition. Do not copy this line into a design where the clock's
# insertion delay matters.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of [get_ports ck_ja0]]

# For an ASYNC_SRC = "STARTUP" build, clk_async comes off STARTUPE2/CFGMCLK
# instead and this file is wrong for it. That variant needs its own constraints
# file rather than a conditional here — see run.tcl.

# sys_clk and clk_async share no source and have no phase relationship. Without
# this, Vivado times every crossing between them against a meaningless
# worst-case alignment and reports enormous, fictional violations.
#
# This is also the single most-abused constraint in the industry: it silences
# the timing report on the crossings but changes NOTHING about the hardware. The
# broken paths below are still broken. It buys the right to a readable timing
# report, and it buys nothing else — which is exactly why the CDC report, not
# the timing report, is the artifact that matters here.
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks clk_async]

# ─────────────────────────────────────────────────────────────────────────────
# CDC — the SAFE crossings, constrained on purpose
# ─────────────────────────────────────────────────────────────────────────────
#
# These live in run.tcl (`apply_cdc_constraints`), not here, and the reason is
# the restricted-command-set note above. They select cells by name pattern, and
# a pattern that matches nothing has to be caught and reported — which needs
# `if`, which this file cannot have. Silently constraining nothing is the single
# most dangerous failure mode in a constraints file: everything downstream reads
# as clean.
#
# What is applied there, immediately after synth_design and before the CDC audit:
#
#   ASYNC_REG TRUE      on gray_meta/gray_sync/req_meta/req_sync/ack_meta/
#                       ack_sync. Keeps each synchronizer pair in one slice, and
#                       is what makes report_synchronizer_mtbf see them at all.
#   set_max_delay -datapath_only  and  set_bus_skew   on the two safe buses:
#                       u_hs/stamp_q -> u_hs/data (handshake, frozen before it
#                       crosses) and hf_gray -> gray_meta (one bit changes per
#                       step). max_delay bounds each bit; set_bus_skew bounds the
#                       SPREAD between them — a design can meet max_delay on all
#                       24 bits and still tear, so the skew bound is the one that
#                       actually protects the crossing.

# ─────────────────────────────────────────────────────────────────────────────
# CDC — the BROKEN crossings, left unconstrained on purpose
# ─────────────────────────────────────────────────────────────────────────────
#
#   hf_count -> u_c/nd_r        (naive direct, 1 flop)
#   hf_count -> u_c/n2_meta     (naive per-bit 2FF — metastability handled,
#                                coherence not; tears just as hard)
#   hf_gray  -> u_c/gray_naked  (gray decoded combinationally with NO
#                                synchronizer; tears WORSE than naive)
#
# There is nothing to write here. That is the finding. Every one of these is a
# real asynchronous crossing that the open iCE40 flow built silently, with no
# lint and no warning, and the hardware then tore ~61k, ~61k and ~114k times a
# second respectively.
#
# `report_cdc` is expected to flag all three (CDC-1 / CDC-4 / CDC-13 class).
# report_cdc.tcl asserts exactly that and fails the run if the count changes —
# so the audit is a regression test, not a document someone has to remember to
# read.
#
# Note what set_clock_groups above did NOT do: it did not make these paths
# disappear from report_cdc. Timing exceptions hide crossings from the timing
# report; the CDC engine walks the netlist structurally and finds them anyway.
# That asymmetry is the entire argument for running both.
