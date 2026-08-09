// top_a7.v — Artix-7 port of the CDC corruption demo (roadmap #5) for the
// Vivado / XSim flow on EC2. Target board: Digilent Arty A7-35T
// (xc7a35ticsg324-1L, 100 MHz oscillator).
//
// The RTL under test is UNCHANGED from the iCE40 project — corrupt.v,
// readout.v, cdc_capture.v and the UART cores are pulled in from their existing
// directories. Only the top level is ported, because only the top level was ever
// vendor-specific: SB_HFOSC (the iCE40 internal RC oscillator) has no direct
// Artix-7 equivalent, and the pins/clock frequencies differ.
//
// ── Why the async clock source is a parameter ────────────────────────────────
// The iCE40 demo got its genuinely-independent clock from SB_HFOSC. The two
// Artix-7 options are NOT equivalent, and the difference is the point:
//
//   ASYNC_SRC = "EXT"      (default) — clk_async comes in on a PMOD pin, driven
//                          by the testbench in simulation. This is what makes
//                          the Vivado flow worth doing: the testbench OWNS the
//                          phase relationship, so post-implementation timing sim
//                          can walk the async edge through the capture flop's
//                          setup/hold aperture deliberately instead of waiting
//                          for drift to do it. On real hardware, feed this pin
//                          from any independent oscillator.
//
//   ASYNC_SRC = "STARTUP"  — CFGMCLK from STARTUPE2: the ~65 MHz internal
//                          configuration ring oscillator. This is the true
//                          SB_HFOSC analogue — free-running, untrimmed, not
//                          derived from the board crystal, so it drifts against
//                          it exactly like the iCE40 version. Use this for a
//                          standalone board run with nothing wired to a PMOD.
//
// What is NOT an option: a second MMCM/PLL output off CLK100MHZ. It would look
// like a separate clock, but it is phase-related to the source and Vivado will
// (correctly) time the crossing as synchronous. You would get a demo that never
// tears and a timing report that says everything is fine — the exact failure
// mode this whole project exists to expose.
//
// No reset net: every register carries an initial value, which Vivado maps to
// the flop INIT attribute and GSR applies at configuration. Same discipline as
// the iCE40 build.

// 115200 baud is right for a board run. Timing simulation is ~5 orders of
// magnitude slower than real time, so the sim builds want a much faster link:
// run.tcl passes -d/-verilog_define BAUD_DEFAULT=6250000 (CLKS_PER_BIT = 16),
// which makes 34 register bytes cost ~110 us of simulated time instead of ~6 ms.
//
// This is a `define rather than a parameter override on purpose. The
// post-implementation netlist is a flat SIMPRIM design with no parameters left
// on it, so the testbench cannot instantiate the DUT with #(...) and have it
// work for both behavioral and timing runs. Baking the value in at
// read/synthesis time is the only way one testbench drives both.
`ifndef BAUD_DEFAULT
`define BAUD_DEFAULT 115200
`endif

module top_a7 #(
    parameter integer CLK_HZ    = 100_000_000,
    parameter integer BAUD      = `BAUD_DEFAULT,
    parameter         ASYNC_SRC = "EXT"     // "EXT" | "STARTUP"
) (
    input        CLK100MHZ,     // E3  — onboard 100 MHz oscillator
    input        ck_ja0,        // G13 — PMOD JA[0], external async clock (EXT)
    input        uart_txd_in,   // A9  — host TX  -> FPGA RX
    output       uart_rxd_out,  // D10 — FPGA TX  -> host RX
    output [3:0] led
);
    localparam integer CPB = CLK_HZ / BAUD;

    wire clk = CLK100MHZ;       // clock-capable pin; Vivado inserts IBUF + BUFG
    wire clk_async;

    // ── The asynchronous domain's clock ──────────────────────────────────────
    generate
        if (ASYNC_SRC == "STARTUP") begin : g_startup
            wire cfgmclk;
            STARTUPE2 #(
                .PROG_USR      ("FALSE"),
                .SIM_CCLK_FREQ (10.0)
            ) u_startup (
                .CFGCLK (), .CFGMCLK (cfgmclk), .EOS (), .PREQ (),
                .CLK (1'b0), .GSR (1'b0), .GTS (1'b0), .KEYCLEARB (1'b1),
                .PACK (1'b0), .USRCCLKO (1'b0), .USRCCLKTS (1'b1),
                .USRDONEO (1'b1), .USRDONETS (1'b1)
            );
            BUFG u_bufg_async (.I (cfgmclk), .O (clk_async));
        end else begin : g_ext
            // ck_ja0 is not a clock-capable pin on the Arty PMOD headers, so the
            // XDC has to set CLOCK_DEDICATED_ROUTE FALSE on this net. That is a
            // deliberate, documented waiver — see the XDC.
            BUFG u_bufg_async (.I (ck_ja0), .O (clk_async));
        end
    endgenerate

    // ── The asynchronous 24-bit counter and its gray code ────────────────────
    (* keep = "true" *) reg [23:0] hf_count = 0;
    (* keep = "true" *) reg [23:0] hf_gray  = 0;
    always @(posedge clk_async) begin
        hf_count <= hf_count + 1'b1;
        hf_gray  <= (hf_count + 1'b1) ^ ((hf_count + 1'b1) >> 1);
    end

    // ── Simulation-only: per-bit routing skew on the crossing ────────────────
    // A behavioral simulator has no setup/hold model, so it can never show this
    // design failing — that is the project's whole thesis and it stays true.
    //
    // But metastability is not the only mechanism, and it is not even the
    // dominant one here. The naive paths fail mostly from BUS SKEW: 24 bits
    // leaving one domain on 24 different routes and arriving at the capture
    // flops at 24 different times, so a sample taken near a transition catches
    // some bits old and some new and assembles a value the counter never held.
    // That is why per-bit 2-flop synchronization does not help — it fixes each
    // bit's metastability and leaves the bits disagreeing about WHICH count they
    // came from. Skew is deterministic, and a behavioral simulator models it
    // perfectly well.
    //
    // These paths are unconstrained by design (see the XDC), which is exactly
    // what licenses the router to skew them. So this models something real.
    //
    // What it does NOT model is metastability. Timing simulation and hardware
    // remain the only places that shows up. Never quote a tear rate from a run
    // with SIM_SKEW defined — the rate is a property of these delay numbers, not
    // of any silicon. It shows the mechanism, not the magnitude.
    //
    // Only the crystal-domain reads get skewed. cdc_capture samples hf_count in
    // its OWN domain, a short local path, so skewing it would be wrong.
    wire [23:0] hf_count_x, hf_gray_x;
`ifdef SIM_SKEW
    // Spread ~2 ns across the bus, against a 15.379 ns source period.
    genvar gi;
    generate
        for (gi = 0; gi < 24; gi = gi + 1) begin : g_skew
            assign #(0.20 + gi * 0.090) hf_count_x[gi] = hf_count[gi];
            assign #(0.20 + gi * 0.090) hf_gray_x[gi]  = hf_gray[gi];
        end
    endgenerate
`else
    assign hf_count_x = hf_count;
    assign hf_gray_x  = hf_gray;
`endif

    // ── Four crystal-domain reads + hardware tear counters (unmodified RTL) ──
    wire [23:0] nd, n2, gray_bin, gray_naked;
    wire [31:0] tear_nd, tear_n2, tear_gray, tear_gnaked;
    wire [47:0] samples;
    corrupt u_c (
        .clk (clk), .async_bin (hf_count_x), .async_gray (hf_gray_x),
        .nd (nd), .n2 (n2), .gray_bin (gray_bin), .gray_naked (gray_naked),
        .tear_nd (tear_nd), .tear_n2 (tear_n2), .tear_gray (tear_gray),
        .tear_gnaked (tear_gnaked), .samples (samples)
    );

    // ── Fifth read: the correct request/ack handshake ────────────────────────
    wire        cdc_start, cdc_valid;
    wire [23:0] cdc_data;
    cdc_capture #(.W (24)) u_hs (
        .clk_slow (clk), .rst_slow (1'b0),
        .start (cdc_start), .busy (), .valid (cdc_valid), .data (cdc_data),
        .clk_fast (clk_async), .rst_fast (1'b0), .fast_value (hf_count)
    );

    // ── UART + register map (unmodified) ─────────────────────────────────────
    wire [7:0] rx_data, tx_data;
    wire       rx_valid, tx_start, tx_busy, active;
    uart_rx #(.CLKS_PER_BIT (CPB)) u_rx (
        .clk (clk), .rx (uart_txd_in), .data (rx_data), .valid (rx_valid));
    uart_tx #(.CLKS_PER_BIT (CPB)) u_tx (
        .clk (clk), .start (tx_start), .data (tx_data),
        .tx (uart_rxd_out), .busy (tx_busy));
    readout u_rd (
        .clk (clk), .rx_data (rx_data), .rx_valid (rx_valid),
        .tx_data (tx_data), .tx_start (tx_start), .tx_busy (tx_busy),
        .cdc_start (cdc_start), .cdc_valid (cdc_valid), .cdc_data (cdc_data),
        .nd (nd), .n2 (n2), .gray_bin (gray_bin), .gray_naked (gray_naked),
        .tear_nd (tear_nd), .tear_n2 (tear_n2), .tear_gray (tear_gray),
        .tear_gnaked (tear_gnaked), .samples (samples), .active (active)
    );

    // led[0] = UART activity; led[3:1] = live "has anything torn yet" flags, so a
    // board run shows the result without a host attached.
    assign led = {(tear_gnaked != 0), (tear_n2 != 0), (tear_nd != 0), active};
endmodule
