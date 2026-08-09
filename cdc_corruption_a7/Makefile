# Makefile — Artix-7 / Vivado port of the CDC corruption demo.
#
# Every target except `smoke` is a thin wrapper around run.tcl and needs the
# Vivado install on the EC2 instance. `make smoke` runs on the Mac.
#
#   make smoke    Icarus + stub primitives — runs on the LAPTOP, no Vivado
#   make trap-skew  LAPTOP: catch a real torn read + dump only the window
#   make behav    behavioral simulation (fast, proves the logic — finds no tears)
#   make synth    synthesis + CDC audit
#   make cdc      re-run the CDC audit on the existing checkpoint
#   make impl     place & route, timing reports, timesim netlist + SDF, bitstream
#   make timing   post-implementation TIMING simulation (the differentiator)
#   make trap     two-pass: find the FIRST tear, dump only the window around it
#   make all      behav -> synth -> impl -> timing, one command
#   make wave     open the last VCD in GTKWave
#   make gui      open the routed checkpoint in the Vivado GUI (use over DCV)
#   make check-sync  prove rtl/ still matches the iCE40 sources
#                  (needs a checkout: make check-sync ICEBREAKER=path/to/icebreaker)
#   make sync     re-copy rtl/ from them
#   make clean
#
# This directory is self-contained: rtl/ holds byte-identical copies of the
# shared cores rather than ../ references, so `rsync -a cdc_corruption_a7/
# instance:` is the entire deployment step.
#
# Deliberately NOT wired into .github/workflows/ci.yml: the CI runner has the
# open toolchain, not Vivado, and this project is the one place in the repo that
# needs a licensed vendor flow. The iCE40 cdc_corruption project remains the
# CI-gated one; this is its cross-check on real STA.

VIVADO ?= vivado
OUT    := build
TOP    := top_a7

# Waveform viewer. Prefer Surfer, and on macOS 26 treat that as mandatory rather
# than a preference:
#
# The Homebrew gtkwave cask is 3.3.107 — a 2020 x86_64 GTK2 build. Getting it to
# start at all took three fixes (unsigned-app quarantine; a Perl launcher that
# needs Switch.pm, dropped from core Perl in 5.14; a bundle launcher that builds
# its own path as `pwd`/$0 and so only works from /). It then segfaults on the
# first text layout, null-dereferencing inside ATSUI — Apple Type Services for
# Unicode Imaging, deprecated in 10.6 and finally non-functional here. That is
# not configurable from our side. The app is done on this OS.
#
# Surfer is in homebrew-core as a bottled native arm64 formula: `brew install
# surfer`. Formulae are not quarantined, so no Gatekeeper detour either. It reads
# VCD, FST and GHW.
WAVE ?= $(firstword $(shell command -v surfer 2>/dev/null) \
                    $(wildcard /Applications/gtkwave.app/Contents/MacOS/gtkwave) \
                    gtkwave)

VRUN = $(VIVADO) -mode batch -nojournal -log $(OUT)/vivado.log -source run.tcl -tclargs

RTL = top_a7.v rtl/corrupt.v rtl/readout.v rtl/cdc_capture.v \
      rtl/uart_rx.v rtl/uart_tx.v

# Testbench parameter overrides for `make smoke`, e.g.
#   make smoke TBP='-Ptb_cdc_corruption.TRIG_MODE=2 -Ptb_cdc_corruption.TRIG_STOP_NS=400'
TBP ?=

# SKEW=1 compiles in the simulation-only per-bit routing skew on the async bus
# (see top_a7.v). Without it a behavioral run cannot tear, by construction.
SKEW ?=
SKEWDEF = $(if $(SKEW),-DSIM_SKEW,)

# Half-width, in ns, of the window `trap-skew` dumps around the first tear.
TRAP_PAD ?= 200

IVFLAGS = -g2012 -DBAUD_DEFAULT=6250000 -DHIER_OK
IVSRC   = -s tb_cdc_corruption tb_cdc_corruption.sv $(RTL) unisim_stub.v

# Where rtl/ came from: the iCE40 repo these cores were lifted from, unchanged.
# That repo is NOT a dependency — nothing in the build reads these paths, and the
# normal state (here, and on the instance) is that it simply is not present.
# Point ICEBREAKER at a checkout to re-verify the copies; see rtl/PROVENANCE.md
# for the exact commit they were taken from.
ICEBREAKER ?= ../../icebreaker
UPSTREAM = $(ICEBREAKER)/fpga/cdc_corruption/corrupt.v \
           $(ICEBREAKER)/fpga/cdc_corruption/readout.v \
           $(ICEBREAKER)/fpga/counter_readout/cdc_capture.v \
           $(ICEBREAKER)/fpga/uart_echo/uart_rx.v \
           $(ICEBREAKER)/fpga/uart_echo/uart_tx.v

.PHONY: help smoke trap-skew behav sim synth cdc impl timing trap all wave gui check-sync sync clean

# Default is help, not a build: `make` here would otherwise kick off a
# place-and-route plus an SDF-annotated timing simulation, which is a long way
# from the sub-second `make` the other projects in this repo have trained me to
# expect. Ask for what you want explicitly.
help:
	@awk 'NR<3{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' Makefile

# The one target that runs without Vivado. Elaborates the real RTL against stub
# BUFG/STARTUPE2 models and exercises the testbench's UART model and the whole
# register map under Icarus, in about a second. It cannot find a CDC failure —
# no behavioral simulation can — but it finds testbench and register-map bugs
# before they cost a round trip to the instance, which is most of what breaks.
smoke:
	@mkdir -p $(OUT)
	iverilog -g2012 -DBAUD_DEFAULT=6250000 -DHIER_OK $(SKEWDEF) $(TBP) \
	  -Ptb_cdc_corruption.DUMP_DEPTH=0 \
	  -o $(OUT)/smoke.vvp -s tb_cdc_corruption tb_cdc_corruption.sv $(RTL) unisim_stub.v
	cd $(OUT) && vvp smoke.vvp
	@echo
	@echo "waveform: $(OUT)/cdc_corruption_a7.vcd   ->  make wave"

# The laptop counterpart of `make trap`: catch a real torn read under Icarus and
# dump only the window around it. Same two-pass structure and the same reason for
# it — a VCD cannot rewind, so nothing can decide to start dumping after the
# interesting thing already happened. Pass 1 dumps nothing and reports when the
# first tear occurred; pass 2 re-runs and dumps +/- TRAP_PAD ns around it. Sound
# only because the testbench is deterministic: no $$random, fixed phase sawtooth,
# so both passes trigger at the identical simulated instant.
#
# SIM_SKEW is forced on here, because without it this target could not terminate:
# a behavioral simulator has no setup/hold model and the naive paths never tear.
# Read the caveat in top_a7.v before quoting any number this produces — the
# mechanism is real, the RATE is a property of the injected delays.
trap-skew:
	@mkdir -p $(OUT)
	@set -e; \
	echo "pass 1 — locating the first tear (no waveform)"; \
	iverilog $(IVFLAGS) -DSIM_SKEW \
	  -Ptb_cdc_corruption.TRIG_MODE=1 \
	  -Ptb_cdc_corruption.TRIG_STOP_NS=10 \
	  -Ptb_cdc_corruption.DUMP_FROM_NS=1e9 \
	  -o $(OUT)/trap1.vvp $(IVSRC); \
	( cd $(OUT) && vvp trap1.vvp ) | tee $(OUT)/trap_pass1.log; \
	T=`sed -n 's/.*first tear at \([0-9.]*\) ns.*/\1/p' $(OUT)/trap_pass1.log | head -1`; \
	if [ -z "$$T" ]; then \
	  echo; \
	  echo "No tear found. With SIM_SKEW on that should not happen — check that"; \
	  echo "the skew spread in top_a7.v is still wide enough relative to"; \
	  echo "ASYNC_PERIOD, or raise OBS_US so the run lasts longer."; \
	  exit 1; \
	fi; \
	LO=`awk -v t=$$T -v p=$(TRAP_PAD) 'BEGIN{printf "%.3f", t-p}'`; \
	HI=`awk -v t=$$T -v p=$(TRAP_PAD) 'BEGIN{printf "%.3f", t+p}'`; \
	echo; \
	echo "pass 2 — first tear at $$T ns; dumping [$$LO, $$HI] ns, full hierarchy"; \
	iverilog $(IVFLAGS) -DSIM_SKEW \
	  -Ptb_cdc_corruption.TRIG_MODE=1 \
	  -Ptb_cdc_corruption.TRIG_STOP_NS=$(TRAP_PAD) \
	  -Ptb_cdc_corruption.DUMP_DEPTH=0 \
	  -Ptb_cdc_corruption.DUMP_FROM_NS=$$LO \
	  -Ptb_cdc_corruption.DUMP_TO_NS=$$HI \
	  -o $(OUT)/trap2.vvp $(IVSRC); \
	( cd $(OUT) && vvp trap2.vvp ) | tee $(OUT)/trap_pass2.log; \
	echo; \
	echo "waveform: $(OUT)/cdc_corruption_a7.vcd  ($$(($(TRAP_PAD)*2)) ns window)"; \
	ls -l $(OUT)/cdc_corruption_a7.vcd

behav sim:
	@mkdir -p $(OUT)
	$(VRUN) behav

synth:
	@mkdir -p $(OUT)
	$(VRUN) synth

cdc:
	@mkdir -p $(OUT)
	$(VRUN) cdc

impl:
	@mkdir -p $(OUT)
	$(VRUN) impl

timing:
	@mkdir -p $(OUT)
	$(VRUN) timing

trap:
	@mkdir -p $(OUT)
	$(VRUN) trap

all:
	@mkdir -p $(OUT)
	$(VRUN) all

# The `cd /` is load-bearing on macOS, and the reason is a genuine bug in the
# bundle launcher: it locates the bundle with tmp="`pwd`/$0", which assumes $0 is
# RELATIVE. Hand it an absolute $0 from any other directory and it builds
# /your/cwd//Applications/gtkwave.app/... and dies. It only works when launched
# by LaunchServices because that sets cwd to /, making the concatenation
# //Applications/... — which happens to resolve. Running from / reproduces that
# by hand. The VCD path is absolute so cwd does not affect the argument.
wave:
	@test -f $(OUT)/cdc_corruption_a7.vcd || { echo "no VCD yet — run 'make smoke' first"; exit 1; }
	cd / && $(WAVE) $(abspath $(OUT)/cdc_corruption_a7.vcd) &

# rtl/ is a vendored copy so this directory stands alone on the instance. The
# cost of vendoring is drift: the whole claim of this project is that it runs the
# *unchanged* iCE40 RTL, and a silently diverged copy turns that claim into a
# lie. These two targets make the claim checkable instead of asserted.
check-sync:
	@ok=1; for f in $(UPSTREAM); do b=`basename $$f`; \
	  if [ ! -f $$f ]; then echo "  skip   $$b (no iCE40 checkout at $(ICEBREAKER))"; \
	  elif diff -q $$f rtl/$$b >/dev/null 2>&1; then echo "  match  $$b"; \
	  else echo "  DRIFT  $$b"; diff -u $$f rtl/$$b | sed -n '1,40p'; ok=0; fi; \
	done; [ $$ok = 1 ] || { echo; echo "rtl/ has diverged from the iCE40 sources."; exit 1; }

sync:
	@for f in $(UPSTREAM); do cp -v $$f rtl/; done

gui:
	$(VIVADO) -mode gui $(OUT)/post_route.dcp &

clean:
	rm -rf $(OUT) xsim.dir .Xil *.jou *.log *.pb *.wdb webtalk*
