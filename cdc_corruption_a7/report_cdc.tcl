# report_cdc.tcl — the constraint / CDC audit.
#
# Sourced by run.tcl with a synthesized (or routed) design already open, or run
# standalone:
#
#   vivado -mode batch -source report_cdc.tcl -tclargs build/post_synth.dcp
#
# This design is a known-answer test for a CDC checker. It contains five
# crossings of the same 24-bit bus: two written correctly and three written
# wrong, on purpose, with the wrongness documented in the XDC. So the report is
# checkable — not "read it and form an impression", but "does the tool find the
# three bugs we planted".
#
# That matters more than it sounds. A CDC report on an unfamiliar design tells
# you what the tool noticed; it does not tell you what the tool MISSES. Running
# it first against a design whose bugs you already know calibrates it. The open
# iCE40 flow scores zero on this test — it has no CDC checker at all, which is
# how the unsynchronized gray crossing got built without a single warning.

if {[llength [get_cells -quiet -hier]] == 0} {
    if {[llength $argv] == 0} { error "no design open and no checkpoint given" }
    open_checkpoint [lindex $argv 0]
}

set cdcdir [file normalize build/cdc]
file mkdir $cdcdir

# ─────────────────────────────────────────────────────────────────────────────
# 1. The CDC report itself
# ─────────────────────────────────────────────────────────────────────────────
report_cdc -details -file $cdcdir/cdc_details.rpt
report_cdc           -file $cdcdir/cdc_summary.rpt

# -details is REQUIRED here, and this is not a stylistic preference. Plain
# `report_cdc -return_string` emits the per-clock-pair summary, whose rows start
# with the severity and contain no CDC-nn rule ID at all. Parsing that for rule
# IDs silently yields zero rows — which on the first real run of this project
# produced a confident "zero Critical findings" on a report that in fact listed
# 72 of them. Only -details carries the `ID Severity Count Description` table.
set cdc_txt [report_cdc -details -return_string]

# Tally by severity, summing the Count column. Rule numbers move between Vivado
# releases, so the severity is what the pass/fail gate keys off; the IDs are kept
# only to print alongside.
array set sev {Critical 0 Warning 0 Info 0}
array set rule {}
set rows 0
foreach line [split $cdc_txt "\n"] {
    if {[regexp {^\s*(CDC-\d+)\s+(Critical|Warning|Info)\s+(\d+)\s+(.*?)\s*$} $line -> r s n d]} {
        incr sev($s) $n
        set rule($r) [format "%-7s %-8s %5d  %s" $r $s $n $d]
        incr rows
    }
}

puts ""
if {$rows == 0} {
    # Distinguish "the tool found nothing" from "we failed to read what it
    # found". Conflating those is how a broken parser masquerades as a clean
    # design — the exact failure this script exists to prevent elsewhere.
    puts "PARSE FAILURE: report_cdc returned [string length $cdc_txt] characters but no"
    puts "  'CDC-nn Severity Count' rows matched. The report format has changed;"
    puts "  the gate below cannot be trusted. First 30 lines as seen:"
    foreach l [lrange [split $cdc_txt "\n"] 0 29] { puts "  | $l" }
} else {
    puts "CDC severity tally:  Critical=$sev(Critical)  Warning=$sev(Warning)  Info=$sev(Info)"
    foreach r [lsort [array names rule]] { puts "  $rule($r)" }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Clock interaction — the other half of the picture
# ─────────────────────────────────────────────────────────────────────────────
# report_cdc walks the netlist structurally. report_clock_interaction reports
# what the TIMING engine thinks about each clock pair, including whether the
# pair is timed, ignored (set_clock_groups / false path), or partially
# constrained. Reading the two side by side is the actual audit: a pair marked
# "Asynchronous Groups" here and "Critical" over there is a crossing someone
# waived in the timing report without fixing in the RTL.
report_clock_interaction -delay_type min_max -significant_digits 3 \
    -file $cdcdir/clock_interaction.rpt

# ─────────────────────────────────────────────────────────────────────────────
# 3. Synchronizer MTBF
# ─────────────────────────────────────────────────────────────────────────────
# Only reports on flop pairs marked ASYNC_REG — which is exactly why the XDC
# marks them. An empty report here means the property did not stick, not that
# the design is safe. The number itself is a placed-and-routed estimate, so it
# is only meaningful after impl; post-synthesis it will be missing or crude.
if {[catch {
    report_synchronizer_mtbf -file $cdcdir/synchronizer_mtbf.rpt
} err]} {
    puts "report_synchronizer_mtbf unavailable here ($err)"
    puts "  — expected on a post-synthesis checkpoint; re-run on post_route.dcp"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Constraint coverage — "your constraints are lying to you"
# ─────────────────────────────────────────────────────────────────────────────
# check_timing finds endpoints with no clock, no input delay, unconstrained
# internal paths — the holes a timing summary reports as "met" because it never
# looked. report_exceptions -ignored finds set_false_path / set_max_delay
# statements that match nothing, i.e. constraints that are quietly doing zero
# while everyone assumes they are load-bearing.
check_timing -file $cdcdir/check_timing.rpt
if {[catch {
    report_exceptions -ignored          -file $cdcdir/exceptions_ignored.rpt
    report_exceptions -coverage -append -file $cdcdir/exceptions_ignored.rpt
} err]} {
    puts "report_exceptions: $err"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Known-answer check
# ─────────────────────────────────────────────────────────────────────────────
# Three deliberately broken crossings: naive-direct (1 flop), naive-per-bit-2FF
# (synchronized but not coherent), and gray-with-no-synchronizer. A CDC checker
# that reports zero critical findings on this design is not working, or the
# netlist got optimized in a way that removed the paths — either way the run is
# not trustworthy and should fail loudly rather than produce a clean report.
set ok 1
if {$rows == 0} {
    puts ""
    puts "AUDIT INVALID: could not parse the CDC report (see PARSE FAILURE above)."
    puts "  This is NOT a statement about the design. Fix the parser first."
    set ok 0
} else {
    if {$sev(Critical) == 0} {
        puts ""
        puts "AUDIT FAILED: zero Critical CDC findings on a design containing three"
        puts "  deliberately broken crossings. Check, in this order:"
        puts "    1. do clk_async and sys_clk BOTH exist? A skipped create_clock"
        puts "       leaves one clock and therefore no crossings at all. Grep the"
        puts "       Vivado log for 'not supported in the xdc constraint file' —"
        puts "       XDC is a restricted command set, not Tcl, and a rejected"
        puts "       block is only a CRITICAL WARNING, not an error."
        puts "    2. did DONT_TOUCH stick? If the naive paths were optimized away"
        puts "       there is nothing left to flag."
        puts "  Read $cdcdir/cdc_details.rpt before trusting any other report here."
        set ok 0
    }
    if {$sev(Info) == 0 && $sev(Warning) == 0} {
        puts ""
        puts "AUDIT WARNING: nothing reported as safely synchronized. The gray+2FF"
        puts "  and handshake paths should appear (CDC-3 / CDC-6, 'synchronized"
        puts "  with ASYNC_REG property'). If they do not, ASYNC_REG failed to"
        puts "  apply — check the cell-name patterns in run.tcl's"
        puts "  apply_cdc_constraints against this netlist."
        set ok 0
    }
}

puts ""
puts "reports written to $cdcdir/"
foreach f [lsort [glob -nocomplain $cdcdir/*.rpt]] { puts "  [file tail $f]" }
if {$ok} { puts "" ; puts "known-answer check: PASS" }
