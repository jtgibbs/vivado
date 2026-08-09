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

# The asynchronous domain. Only one of these two exists in any given build.
if {[llength [get_ports -quiet ck_ja0]] && \
    [llength [get_nets -quiet -of [get_ports ck_ja0]]]} {
    # 65 MHz nominal, matching the internal ring oscillator this stands in for.
    # Constrain it FASTER than the testbench drives it: the async domain's own
    # internal timing must close with margin, or a failure inside that domain
    # would masquerade as a CDC failure and the whole measurement is worthless.
    create_clock -name clk_async -period 14.000 [get_ports ck_ja0]

    # ck_ja0 is a general-purpose I/O, not a clock-capable pin, so it cannot
    # reach a BUFG on the dedicated clock route. This waiver is safe HERE and
    # only here: the async domain is a free-running counter whose absolute skew
    # to anything else is irrelevant by definition. Do not copy this line into a
    # design where the clock's insertion delay matters.
    set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of [get_ports ck_ja0]]
}
set cfgmclk [get_pins -quiet g_startup.u_startup/CFGMCLK]
if {[llength $cfgmclk]} {
    # STARTUPE2 CFGMCLK is an untrimmed ring oscillator: ~65 MHz nominal with a
    # very wide process/voltage/temperature spread. Constrain the fast corner.
    create_clock -name clk_async -period 10.000 $cfgmclk
}

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

# ASYNC_REG on every first- and second-stage synchronizer flop. Two effects,
# both required: the placer keeps the pair in the same slice (maximising the
# settling time available to stage 2), and Vivado stops flagging them as
# unsynchronized crossings — and starts including them in
# report_synchronizer_mtbf.
set async_reg_cells [get_cells -quiet -hier -regexp \
    {.*(gray_meta|gray_sync|req_meta|req_sync|ack_meta|ack_sync)_reg(\[\d+\])?}]
if {[llength $async_reg_cells]} {
    set_property ASYNC_REG TRUE $async_reg_cells
}

# Handshake data bus: stamp_q (clk_async) -> data (sys_clk). The four-phase
# handshake guarantees stamp_q is frozen for several cycles before sys_clk
# samples it, so this path needs no setup/hold relationship — only a bound so
# the router cannot stretch it past the time the handshake actually allows.
# -datapath_only removes the source clock's uncertainty from the calculation;
# the number is one destination period.
set hs_launch [get_cells -quiet -hier -regexp {.*u_hs/stamp_q_reg(\[\d+\])?}]
set hs_latch  [get_cells -quiet -hier -regexp {.*u_hs/data_reg(\[\d+\])?}]
if {[llength $hs_launch] && [llength $hs_latch]} {
    set_max_delay -datapath_only -from $hs_launch -to $hs_latch 10.000
    # Bus skew is the constraint that actually matters for a multi-bit crossing:
    # max delay bounds each bit, set_bus_skew bounds the SPREAD between them.
    # A design can meet max_delay on all 24 bits and still tear.
    set_bus_skew -from $hs_launch -to $hs_latch 10.000
}

# Gray-coded bus: hf_gray (clk_async) -> gray_meta (sys_clk). Only one bit
# changes per step, so a bit caught mid-transition resolves to either the old or
# the new value and both are legal — but only if the skew across the bus is
# under one source period, or two bits can appear to change at once and the
# gray property is lost.
set gray_launch [get_cells -quiet -hier -regexp {.*hf_gray_reg(\[\d+\])?}]
set gray_latch  [get_cells -quiet -hier -regexp {.*gray_meta_reg(\[\d+\])?}]
if {[llength $gray_launch] && [llength $gray_latch]} {
    set_max_delay -datapath_only -from $gray_launch -to $gray_latch 10.000
    set_bus_skew  -from $gray_launch -to $gray_latch 14.000
}

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
