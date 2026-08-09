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
set cdc_txt [report_cdc -return_string]

# Tally by severity. Rule numbers move between Vivado releases, so key off the
# severity column rather than hard-coding CDC-1 / CDC-4 / CDC-13.
array set sev {Critical 0 Warning 0 Info 0}
array set rule {}
foreach line [split $cdc_txt "\n"] {
    if {[regexp {(CDC-\d+)\s+(Critical|Warning|Info)} $line -> r s]} {
        incr sev($s)
        if {![info exists rule($r)]} { set rule($r) [string trim $line] }
    }
}

puts ""
puts "CDC severity tally:  Critical=$sev(Critical)  Warning=$sev(Warning)  Info=$sev(Info)"
foreach r [lsort [array names rule]] { puts "  $rule($r)" }

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
if {$sev(Critical) == 0} {
    puts ""
    puts "AUDIT FAILED: zero Critical CDC findings on a design containing three"
    puts "  deliberately broken crossings. Either the DONT_TOUCH properties in"
    puts "  run.tcl did not stick and the naive paths were optimized away, or"
    puts "  this Vivado version classifies them below Critical. Read"
    puts "  $cdcdir/cdc_details.rpt before trusting any other report here."
    set ok 0
}
if {$sev(Info) == 0} {
    puts ""
    puts "AUDIT WARNING: zero Info findings. The gray+2FF and handshake"
    puts "  synchronizers should be recognised and reported as safe. If they are"
    puts "  not being seen, ASYNC_REG probably failed to apply — check the cell"
    puts "  name patterns in cdc_corruption_a7.xdc against this netlist."
    set ok 0
}

puts ""
puts "reports written to $cdcdir/"
foreach f [lsort [glob -nocomplain $cdcdir/*.rpt]] { puts "  [file tail $f]" }
if {$ok} { puts "" ; puts "known-answer check: PASS" }
