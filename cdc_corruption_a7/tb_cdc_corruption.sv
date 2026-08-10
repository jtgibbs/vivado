// tb_cdc_corruption.sv — XSim testbench for the Artix-7 CDC corruption port.
//
// Deliberately drives NOTHING but the top-level pins: 100 MHz clock, the async
// clock, and the UART pair. That constraint is what lets the identical
// testbench run against three different things —
//
//   behavioral RTL          — proves the logic and the register map
//   post-synthesis netlist  — proves synthesis kept the flops we depend on
//   post-implementation     — SDF-annotated, with real cell delays and real
//     timing simulation       $setuphold checks on every flop
//
// — and it is the third one that justifies the whole Vivado detour. Behavioral
// simulation cannot show this failure, for the reason stated in the iCE40
// project: the simulator has no setup/hold model at an async boundary, every
// sample is deterministic, and the tear counters stay at zero. A timing
// simulation DOES have that model. When the async counter's output violates the
// capture flop's setup or hold window, the SIMPRIM model emits a timing
// violation and drives X.
//
// So the three environments disagree in a specific and useful way:
//
//   behavioral   : naive reads look perfect.          (the lie)
//   timing sim   : naive reads go X on violation.     (the tool knows)
//   hardware     : naive reads return a wrong number. (the truth)
//
// X is not what the silicon does — silicon resolves to *some* value, and that
// value is what the iCEBreaker board measured. X is the simulator refusing to
// guess. Treat an X here as "this bit was unknowable", which is the honest
// answer, and go to the board for what it actually resolves to.
//
// Reproducibility: no $random anywhere. The async clock's phase walk is a fixed
// sawtooth, so two runs of the same netlist give byte-identical output.

`timescale 1ns / 1ps

module tb_cdc_corruption;

    // ── Parameters (override with xelab -generic_top) ────────────────────────
    parameter real    CLK_PERIOD   = 10.000;   // 100 MHz system clock
    parameter real    ASYNC_PERIOD = 15.379;   // ~65 MHz, deliberately not a
                                               // rational multiple of 10 ns
    parameter real    ASYNC_DRIFT  = 0.010;    // ns added per async cycle, then
                                               // wrapped — walks the async edge
                                               // through the capture aperture
                                               // instead of waiting for luck
    parameter integer CLKS_PER_BIT = 16;       // MUST match the DUT build
    parameter integer OBS_US       = 50;       // observation window before read
    parameter integer DUMP_DEPTH   = 2;        // 0 = everything (huge on a
                                               // routed netlist); 2 = tb + DUT
                                               // ports, enough to see the UART

    // ── Trigger / windowed dump ──────────────────────────────────────────────
    // Scanning a 5 MB waveform for a transient is the wrong tool. These let the
    // simulator stop AT the event and say what it was.
    //
    // TRIG_MODE  0 off · 1 first tear · 2 first DUT UART reply · 3 exact count
    //
    // Mode 1 watches led[3:1], which top_a7 drives from the tear counters. That
    // is deliberate and it is the only mode that survives the trip to timing
    // simulation: in the post-implementation netlist `dut.u_c.tear_nd` does not
    // exist as a bus — Vivado flattens it into 32 separately-named flops — so a
    // hierarchical reference from here would break. A top-level PIN is
    // observable identically in behavioral sim, timing sim, and on the board.
    // Mode 3 does use a hierarchical reference and is therefore behavioral-only;
    // it is compiled out unless HIER_OK is defined.
    parameter integer TRIG_MODE     = 0;
    // Extra settle before the tear trigger arms. Default 0 — arming happens at
    // rx_enable, already 900 ns after GSR releases — and that default is the
    // result of getting this wrong twice, in opposite directions.
    //
    // led[3:1] are STICKY: they latch "this counter is non-zero" and never
    // clear. So `wait (led != 0)` does not mean "first tear", it means "any tear
    // ever, including during reset". In post-implementation timing simulation
    // gray_naked always scores one during GSR — it decodes the raw async bus
    // combinationally and registers it once, so as the flops leave global reset
    // it samples garbage and the detector sees an enormous step. First attempt
    // therefore triggered at exactly t=1000 ns on a reset artifact.
    //
    // The fix that overshot: wait 3 us, then arm. By 3 us ALL THREE counters are
    // dirty — tears here run about 1/us — so the mask covered everything and the
    // trigger could never fire. That masked the real events, not the artifact.
    //
    // What actually works: arm immediately, snapshot which bits are already set
    // (gray_naked, from GSR), and fire on the first bit to go dirty AFTER that —
    // naive_direct or naive_2ff, which are the interesting ones anyway. Raise
    // this only if a future netlist shows genuine post-GSR settling.
    parameter real    TRIG_ARM_NS   = 0.0;
    parameter [23:0]  TRIG_COUNT    = 24'h000000;  // mode 3 target
    parameter real    TRIG_STOP_NS  = 0.0;   // >0: $finish this long after trigger
    // A VCD cannot rewind, so a single run cannot decide to start dumping after
    // the interesting thing already happened. Hence two passes: pass 1 dumps
    // nothing and reports the trigger time, pass 2 re-runs and dumps only the
    // window around it. That only works because this testbench is deterministic
    // — no $random, fixed phase sawtooth — so the same build triggers at the
    // same time every run. Leave both at 0 to dump the whole run.
    parameter real    DUMP_FROM_NS  = 0.0;
    parameter real    DUMP_TO_NS    = 0.0;

    localparam real BIT_TIME = CLKS_PER_BIT * CLK_PERIOD;

    // ── DUT ──────────────────────────────────────────────────────────────────
    reg        CLK100MHZ   = 1'b0;
    reg        ck_ja0      = 1'b0;
    reg        uart_txd_in = 1'b1;   // host -> FPGA, idle high
    wire       uart_rxd_out;         // FPGA -> host
    wire [3:0] led;

    top_a7 dut (
        .CLK100MHZ    (CLK100MHZ),
        .ck_ja0       (ck_ja0),
        .uart_txd_in  (uart_txd_in),
        .uart_rxd_out (uart_rxd_out),
        .led          (led)
    );

    // ── Clocks ───────────────────────────────────────────────────────────────
    always #(CLK_PERIOD / 2.0) CLK100MHZ = ~CLK100MHZ;

    // The async clock. Its period ramps by ASYNC_DRIFT each cycle over a 1 ns
    // span and then resets, so across the observation window every possible
    // phase relationship to the 100 MHz edge occurs — including the ones that
    // land the data transition inside the capture flop's setup/hold window.
    // On hardware this happens by itself, slowly, because two oscillators
    // always drift. In simulation nothing drifts unless you make it, and a
    // fixed rational ratio would sample the SAME phase forever and find
    // nothing.
    real async_half = ASYNC_PERIOD / 2.0;
    real async_walk = 0.0;
    always begin
        #(async_half + async_walk) ck_ja0 = ~ck_ja0;
        if (ck_ja0 == 1'b0) begin
            async_walk = async_walk + ASYNC_DRIFT;
            if (async_walk > 1.0) async_walk = 0.0;
        end
    end

    // ── UART host model (8N1, matched to the DUT's CLKS_PER_BIT) ─────────────
    task automatic uart_put(input [7:0] b);
        integer i;
        begin
            uart_txd_in = 1'b0;                       // start
            #(BIT_TIME);
            for (i = 0; i < 8; i = i + 1) begin       // LSB first
                uart_txd_in = b[i];
                #(BIT_TIME);
            end
            uart_txd_in = 1'b1;                       // stop
            #(BIT_TIME);
        end
    endtask

    // Receive is a free-running background monitor feeding a queue, NOT a task
    // called when a byte is expected. That is not gold-plating — a
    // call-when-expected receiver loses bytes here, and it took a simulation to
    // see why: uart_rx asserts `valid` when it samples the CENTRE of the stop
    // bit, one full bit time before the host has finished shifting the frame
    // out. So the DUT starts replying while the host is still transmitting, and
    // any receiver that only starts listening after its send() returns has
    // already missed the reply's start bit. Full duplex is not optional.
    reg [7:0] rxq [0:255];
    integer   rxq_wr = 0, rxq_rd = 0;
    reg       rx_enable = 1'b0;    // held off until GSR releases
    reg [7:0] rxb;
    integer   ri;

    always begin
        if (!rx_enable) @(posedge rx_enable);
        @(negedge uart_rxd_out);                      // start bit
        #(BIT_TIME * 1.5);                            // centre of bit 0
        for (ri = 0; ri < 8; ri = ri + 1) begin
            rxb[ri] = uart_rxd_out;
            #(BIT_TIME);
        end
        rxq[rxq_wr % 256] = rxb;                      // now mid stop bit
        rxq_wr = rxq_wr + 1;
    end

    task automatic uart_get(output [7:0] b);
        begin
            wait (rxq_wr != rxq_rd);
            b     = rxq[rxq_rd % 256];
            rxq_rd = rxq_rd + 1;
        end
    endtask

    // Read one register: send the address, collect `n` big-endian bytes.
    task automatic read_reg(input [7:0] addr, input integer n,
                            output reg [47:0] val, output reg sawx);
        integer i;
        reg [7:0] b;
        begin
            val  = 48'h0;
            sawx = 1'b0;
            uart_put(addr);
            for (i = 0; i < n; i = i + 1) begin
                uart_get(b);
                if (^b === 1'bx) sawx = 1'b1;
                val = {val[39:0], b};
            end
        end
    endtask

    // ── Stimulus ─────────────────────────────────────────────────────────────
    reg [47:0] hs, v_nd, v_n2, v_gray, v_gnaked;
    reg [47:0] t_nd, t_n2, t_gray, t_gnaked, samp;
    reg        x_hs, x_nd, x_n2, x_gray, x_gnaked, xt;
    real       secs;

    // ── Windowed dump ────────────────────────────────────────────────────────
    initial begin
        $dumpfile("cdc_corruption_a7.vcd");
        $dumpvars(DUMP_DEPTH, tb_cdc_corruption);
        if (DUMP_FROM_NS > 0.0) begin
            $dumpoff;
            #(DUMP_FROM_NS);
            $dumpon;
            if (DUMP_TO_NS > DUMP_FROM_NS) begin
                #(DUMP_TO_NS - DUMP_FROM_NS);
                $dumpoff;
            end
        end
    end

    // ── Trigger ──────────────────────────────────────────────────────────────
    real trig_ns = -1.0;
    reg [2:0] arm_mask = 3'b000;   // tear bits already dirty when we armed

    initial begin
        @(posedge rx_enable);          // ignore anything before GSR releases
        case (TRIG_MODE)
            1: begin
                if (TRIG_ARM_NS > 0.0) #(TRIG_ARM_NS);
                arm_mask = led[3:1];
                if (arm_mask != 3'b000) begin
                    $display("");
                    $display("NOTE: led[3:1] = %b already set at arm (%0.0f ns) — startup",
                             arm_mask, $realtime);
                    $display("      artifact, not a CDC event. Those bits are excluded;");
                    $display("      trigger will fire on a counter that goes dirty later.");
                end
                wait ((led[3:1] & ~arm_mask) != 3'b000);
                trig_ns = $realtime;
                $display("");
                $display("TRIGGER  first tear at %0.3f ns", trig_ns);
                $display("         led[3:1] = %b  (gray_naked, naive_2ff, naive_direct)",
                         led[3:1]);
                $display("         newly set = %b", led[3:1] & ~arm_mask);
                report_paths;
            end
            2: begin
                @(negedge uart_rxd_out);
                trig_ns = $realtime;
                $display("");
                $display("TRIGGER  first DUT reply start bit at %0.3f ns", trig_ns);
                report_paths;
            end
`ifdef HIER_OK
            3: begin
                wait (dut.hf_count == TRIG_COUNT);
                trig_ns = $realtime;
                $display("");
                $display("TRIGGER  hf_count reached %06h at %0.3f ns", TRIG_COUNT, trig_ns);
                report_paths;
            end
`endif
            default: ;
        endcase

        if (trig_ns >= 0.0 && TRIG_STOP_NS > 0.0) begin
            #(TRIG_STOP_NS);
            $display("stopping %0.1f ns after trigger", TRIG_STOP_NS);
            $display("");
            $finish;
        end
    end

    // What the five read paths hold at this instant. Hierarchical, so
    // behavioral-only — in a timing run the trigger still fires and still
    // reports its time, which is what pass 1 of the two-pass flow needs.
    task automatic report_paths;
        begin
`ifdef HIER_OK
            $display("         hf_count   %06h   (the async counter right now)",
                     dut.hf_count);
            $display("         nd         %06h   n2         %06h",
                     dut.nd, dut.n2);
            $display("         gray_bin   %06h   gray_naked %06h",
                     dut.gray_bin, dut.gray_naked);
            $display("         tears  nd=%0d  n2=%0d  gray=%0d  gnaked=%0d",
                     dut.tear_nd, dut.tear_n2, dut.tear_gray, dut.tear_gnaked);
`endif
        end
    endtask

    initial begin

        // GSR is asserted for the first 100 ns of a timing simulation (glbl).
        // Nothing the DUT does before that is meaningful — and uart_rxd_out is
        // X until it releases, so the receive monitor must stay parked or it
        // will trigger on the X->0 transition and frame on garbage.
        #1000;
        rx_enable = 1'b1;

        $display("");
        $display("=== CDC corruption — Artix-7 / XSim ===");
        $display("sys 100 MHz | async %0.3f ns nominal, drifting %0.3f ns/cycle",
                 ASYNC_PERIOD, ASYNC_DRIFT);
        $display("observation window: %0d us", OBS_US);
        $display("");

        #(OBS_US * 1000.0);

        // 0x00 latches the coherent snapshot; everything after reads out of it.
        read_reg(8'h00, 3, hs,       x_hs);
        read_reg(8'h01, 3, v_nd,     x_nd);
        read_reg(8'h02, 3, v_n2,     x_n2);
        read_reg(8'h03, 3, v_gray,   x_gray);
        read_reg(8'h08, 3, v_gnaked, x_gnaked);
        read_reg(8'h04, 4, t_nd,     xt);
        read_reg(8'h05, 4, t_n2,     xt);
        read_reg(8'h06, 4, t_gray,   xt);
        read_reg(8'h09, 4, t_gnaked, xt);
        read_reg(8'h07, 6, samp,     xt);

        secs = samp / 100.0e6;

        $display("snapshot @ %0d samples (%0.6f s of 100 MHz clock)", samp, secs);
        $display("");
        $display("  read path             value   vs handshake  X?");
        $display("  --------------------  ------  ------------  --");
        $display("  handshake   (0x00)    %h            --  %s",
                 hs[23:0],       x_hs     ? "X" : " ");
        $display("  gray + 2FF  (0x03)    %h  %12d  %s", v_gray[23:0],
                 $signed({{16{1'b0}}, v_gray[23:0]}   - {16'h0, hs[23:0]}), x_gray   ? "X" : " ");
        $display("  naive dir   (0x01)    %h  %12d  %s", v_nd[23:0],
                 $signed({{16{1'b0}}, v_nd[23:0]}     - {16'h0, hs[23:0]}), x_nd     ? "X" : " ");
        $display("  naive 2FF   (0x02)    %h  %12d  %s", v_n2[23:0],
                 $signed({{16{1'b0}}, v_n2[23:0]}     - {16'h0, hs[23:0]}), x_n2     ? "X" : " ");
        $display("  gray NO sync(0x08)    %h  %12d  %s", v_gnaked[23:0],
                 $signed({{16{1'b0}}, v_gnaked[23:0]} - {16'h0, hs[23:0]}), x_gnaked ? "X" : " ");
        $display("");
        $display("  hardware tear counters over the window");
        $display("  ---------------------  ---------  --------------");
        report_tears("gray + 2FF   (safe)", t_gray,   secs);
        report_tears("handshake    (safe)", 48'd0,    secs);
        report_tears("naive direct       ", t_nd,     secs);
        report_tears("naive per-bit 2FF  ", t_n2,     secs);
        report_tears("gray, NO sync      ", t_gnaked, secs);
        $display("");

        if (t_nd == 0 && t_n2 == 0 && t_gnaked == 0) begin
            $display("NOTE: zero tears. Expected for BEHAVIORAL simulation — there is no");
            $display("      setup/hold model, so every async sample is deterministic and");
            $display("      clean. If this is the post-implementation timing run, the");
            $display("      async edge never landed in a capture aperture: raise OBS_US,");
            $display("      or nudge ASYNC_PERIOD / ASYNC_DRIFT.");
        end else begin
            $display("Naive paths tore. gray+2FF and the handshake did not.");
        end

        if (t_gray != 0) begin
            $display("FAIL: the gray+2FF path tore (%0d). That path is supposed to be", t_gray);
            $display("      correct — investigate that before believing anything else here.");
        end

        $display("");
        $finish;
    end

    task automatic report_tears(input [8*20:1] name, input [47:0] n, input real s);
        begin
            $display("  %0s  %9d  %10.0f /s", name, n, (s > 0.0) ? n / s : 0.0);
        end
    endtask

    // Safety net: a timing sim that goes badly wrong can hang in uart_get
    // waiting for a start bit that never comes.
    initial begin
        #(OBS_US * 1000.0 + 40_000_000.0 / CLKS_PER_BIT + 500_000.0);
        $display("TIMEOUT — UART readout did not complete. Check that the testbench's");
        $display("          CLKS_PER_BIT (%0d) matches the BAUD the netlist was built", CLKS_PER_BIT);
        $display("          with; a mismatch here reads as a hang, not an error.");
        $finish;
    end

endmodule
