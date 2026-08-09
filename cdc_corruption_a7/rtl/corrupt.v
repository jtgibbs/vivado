// corrupt.v — four crystal-domain read paths of one async counter (naive x2,
// gray x2), right and wrong. The fifth read — the handshake — is in top.v, for
// five ways total.
//
// A 24-bit counter runs in the HFOSC domain (genuinely async to the crystal —
// see top.v). This module reads it four ways and counts, in hardware, how often
// each read *tears*: produces a value the counter never held.
//
//   nd   — NAIVE DIRECT: one flop per bit, no coordination. Wrong.
//   n2   — NAIVE per-bit 2-FLOP: every bit through a proper 2-flop synchronizer.
//          Looks textbook-correct, has no metastability... and STILL tears,
//          because the bits resolve to different counter values. This is the
//          insidious case — the whole point of the demo.
//   gray — GRAY-CODED: the counter is gray-encoded in its own domain (only one
//          bit changes per step), 2-flop synchronized, then decoded. Correct.
//   (handshake — the coherent request/ack read — lives in top.v via cdc_capture.)
//
// Tear detector: a coherent read advances by a small, bounded step each crystal
// clock (the async counter runs ~4x the sample clock). A torn read jumps by a
// large amount (a high bit caught mid-carry) or goes backwards. Count steps
// larger than STEP_MARGIN. `gray` should count ~zero; nd and n2 should not.
//
// None of this appears in RTL simulation — with no setup/hold model the samples
// are deterministic and never tear, so the counters stay zero here. Hardware only.

module corrupt #(
    parameter integer W           = 24,
    parameter integer STEP_MARGIN = 64,   // max plausible coherent step per clock
    parameter integer EW          = 32,   // tear counter width
    parameter integer SW          = 48    // sample (run-time) counter width
) (
    input                clk,             // crystal domain
    input      [W-1:0]   async_bin,       // the async counter (raw binary)
    input      [W-1:0]   async_gray,      // the async counter, gray-coded in its domain
    output reg [W-1:0]   nd,              // naive direct read
    output reg [W-1:0]   n2,              // naive per-bit 2-flop read
    output     [W-1:0]   gray_bin,        // gray path, 2-flop synced then decoded
    output reg [W-1:0]   gray_naked,      // gray path, decoded with NO synchronizer
    output reg [EW-1:0]  tear_nd,
    output reg [EW-1:0]  tear_n2,
    output reg [EW-1:0]  tear_gray,
    output reg [EW-1:0]  tear_gnaked,
    output reg [SW-1:0]  samples
);
    localparam integer MARG = STEP_MARGIN;

    // NAIVE DIRECT — one flop. (* keep *) so it isn't merged with the 2-flop chain.
    (* keep *) reg [W-1:0] nd_r = 0;
    always @(posedge clk) nd_r <= async_bin;
    always @(posedge clk) nd <= nd_r;      // one extra reg so `nd` and n2 line up in depth

    // NAIVE per-bit 2-FLOP — independent chain.
    (* keep *) reg [W-1:0] n2_meta = 0;
    always @(posedge clk) begin
        n2_meta <= async_bin;
        n2      <= n2_meta;
    end

    // GRAY — 2-flop sync the gray code (one bit changes at a time, so this is
    // safe), then decode to binary.  bin[i] = ^gray[W-1:i]
    (* keep *) reg [W-1:0] gray_meta = 0, gray_sync = 0;
    always @(posedge clk) begin
        gray_meta <= async_gray;
        gray_sync <= gray_meta;
    end
    integer i;
    reg [W-1:0] gb;
    always @* begin
        gb[W-1] = gray_sync[W-1];
        for (i = W-2; i >= 0; i = i - 1) gb[i] = gb[i+1] ^ gray_sync[i];
    end
    assign gray_bin = gb;

    // GRAY WITHOUT A SYNCHRONIZER — decode the RAW async gray combinationally, then
    // register once. Gray fixed *coherence*, but with no synchronizer the one
    // transitioning gray bit is metastable when the decoder reads it, and the
    // decode fans it across many binary bits, which this single register can latch
    // inconsistently -> torn again. Same gray code, synchronizer removed.
    // (The tools build this silently — no CDC lint in the open flow; a real STA
    //  flow's report_cdc would flag the crossing. Hardware, or Vivado, reveals it.)
    integer k;
    reg [W-1:0] gnb;
    always @* begin
        gnb[W-1] = async_gray[W-1];
        for (k = W-2; k >= 0; k = k - 1) gnb[k] = gnb[k+1] ^ async_gray[k];
    end
    (* keep *) always @(posedge clk) gray_naked <= gnb;

    // Tear detection: flag a per-clock step larger than the plausible coherent
    // advance (also catches backward jumps, which wrap to a large forward step).
    reg [W-1:0] nd_p = 0, n2_p = 0, gray_p = 0, gnaked_p = 0;
    always @(posedge clk) begin
        nd_p     <= nd;
        n2_p     <= n2;
        gray_p   <= gray_bin;
        gnaked_p <= gray_naked;
    end
    wire [W-1:0] nd_step     = nd         - nd_p;
    wire [W-1:0] n2_step     = n2         - n2_p;
    wire [W-1:0] gray_step   = gray_bin   - gray_p;
    wire [W-1:0] gnaked_step = gray_naked - gnaked_p;

    always @(posedge clk) begin
        samples <= samples + 1'b1;
        if (nd_step     > MARG[W-1:0]) tear_nd     <= tear_nd     + 1'b1;
        if (n2_step     > MARG[W-1:0]) tear_n2     <= tear_n2     + 1'b1;
        if (gray_step   > MARG[W-1:0]) tear_gray   <= tear_gray   + 1'b1;
        if (gnaked_step > MARG[W-1:0]) tear_gnaked <= tear_gnaked + 1'b1;
    end

    initial begin
        nd = 0; n2 = 0; gray_naked = 0;
        tear_nd = 0; tear_n2 = 0; tear_gray = 0; tear_gnaked = 0; samples = 0;
    end
endmodule
