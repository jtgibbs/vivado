// cdc_capture.v — coherent multi-bit read across an asynchronous clock boundary.
//
// Samples a free-running value that lives in the FAST clock domain and delivers
// it, intact, into the SLOW clock domain on request. This is the v2 crossing:
// the 12 MHz side asks for the 48 MHz counter, and gets back a value the counter
// actually held — never a torn mix of bits captured on different edges.
//
// Why not just two-flop-synchronize the 32 bits? Because independent per-bit
// synchronizers resolve on different clocks and hand back a value that never
// existed — the multi-bit corruption failure. The fix is a four-phase handshake
// that makes the data *static* before it crosses:
//
//   1. slow domain raises  req            (a level)
//   2. req crosses to fast via 2 flops -> req_sync
//   3. fast domain latches fast_value -> stamp_q  (one edge, atomic) and raises ack
//   4. ack crosses back to slow via 2 flops -> ack_sync
//   5. slow domain samples stamp_q (now stable for many cycles) into `data`,
//      pulses `valid`, and drops req
//   6. fast drops ack; slow returns to idle — ready for the next request
//
// The multi-bit bus stamp_q -> data crosses fast->slow, but only *after* the
// handshake guarantees stamp_q has been frozen for several cycles, so its bits
// are not transitioning when the slow domain samples them. A real STA flow bounds
// that bus with set_max_delay -datapath_only / set_bus_skew (see CONSTRAINTS.md);
// the open flow cannot, so (* keep *) at least preserves the synchronizer flops.
//
// Resets are per-domain and assumed already synchronized to their own clock (see
// the reset synchronizers in top.v). Both are synchronous, active-high.

module cdc_capture #(
    parameter integer W = 32
) (
    // slow (request/read) domain
    input              clk_slow,
    input              rst_slow,
    input              start,        // 1-cycle strobe: begin a coherent read
    output reg         busy,         // high from start until data is delivered
    output reg         valid,        // 1-cycle strobe: `data` is fresh
    output reg [W-1:0] data,         // the coherent captured value

    // fast (source) domain
    input              clk_fast,
    input              rst_fast,
    input      [W-1:0] fast_value    // free-running value to be sampled
);
    // ---- request path: req_launch (slow) -> req_sync (fast) -------------------
    reg req_launch = 1'b0;                     // driven by the slow FSM below
    (* keep *) reg req_meta = 1'b0, req_sync = 1'b0;
    always @(posedge clk_fast) begin
        if (rst_fast) {req_sync, req_meta} <= 2'b00;
        else          {req_sync, req_meta} <= {req_meta, req_launch};
    end

    // ---- fast domain: capture on the rising edge of the synced request --------
    reg              req_sync_d = 1'b0;
    (* keep *) reg [W-1:0] stamp_q = {W{1'b0}};
    reg              ack_launch = 1'b0;
    always @(posedge clk_fast) begin
        if (rst_fast) begin
            req_sync_d <= 1'b0;
            stamp_q    <= {W{1'b0}};
            ack_launch <= 1'b0;
        end else begin
            req_sync_d <= req_sync;
            if (req_sync & ~req_sync_d) stamp_q <= fast_value;  // atomic latch
            ack_launch <= req_sync;                              // ack tracks req
        end
    end

    // ---- ack path: ack_launch (fast) -> ack_sync (slow) -----------------------
    (* keep *) reg ack_meta = 1'b0, ack_sync = 1'b0;
    always @(posedge clk_slow) begin
        if (rst_slow) {ack_sync, ack_meta} <= 2'b00;
        else          {ack_sync, ack_meta} <= {ack_meta, ack_launch};
    end

    // ---- slow domain: four-phase handshake FSM --------------------------------
    localparam [1:0] S_IDLE = 2'd0,   // waiting for a request
                     S_WAIT = 2'd1,   // req asserted, waiting for ack
                     S_DROP = 2'd2;   // sampled; waiting for ack to fall

    reg [1:0] state = S_IDLE;
    always @(posedge clk_slow) begin
        valid <= 1'b0;
        if (rst_slow) begin
            req_launch <= 1'b0;
            busy       <= 1'b0;
            data       <= {W{1'b0}};
            state      <= S_IDLE;
        end else case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    req_launch <= 1'b1;
                    busy       <= 1'b1;
                    state      <= S_WAIT;
                end
            end
            S_WAIT: if (ack_sync) begin       // fast side has frozen stamp_q
                data       <= stamp_q;         // multi-bit sample of a static value
                valid      <= 1'b1;
                req_launch <= 1'b0;
                state      <= S_DROP;
            end
            S_DROP: if (!ack_sync) begin       // handshake fully retired
                busy  <= 1'b0;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end

`ifdef FORMAL
    // Formal properties for the handshake PROTOCOL (yosys write_smt2 + smtbmc;
    // excluded from sim/synth). Proven under a synchronous model of the two
    // clocks — this verifies the FSM/handshake logic. The *asynchronous* safety
    // (no metastability across the crossing) rests on the two-flop synchronizer
    // structure and the timing bounds in CONSTRAINTS.md, which the open formal
    // flow cannot model; that is an sby --multiclock / MTBF matter (roadmap #4).
    reg f_past_valid = 1'b0;
    always @(posedge clk_slow) f_past_valid <= 1'b1;

    // The slow FSM never leaves its three defined states.
    always @(*) assert(state == S_IDLE || state == S_WAIT || state == S_DROP);

    // `valid` is a one-cycle strobe — never asserted two cycles in a row.
    always @(posedge clk_slow) if (f_past_valid && $past(valid)) assert(!valid);

    // When `valid` pulses, `data` equals the value the fast side captured and
    // held — the slow domain samples the frozen stamp, never a torn mix.
    always @(posedge clk_slow) if (f_past_valid && valid) assert(data == stamp_q);

    // `data` is stable except on the cycle it is delivered.
    always @(posedge clk_slow) if (f_past_valid && !$past(valid))
        assert(data == $past(data));

    // A transaction raises busy: accepting `start` in IDLE implies busy next.
    always @(posedge clk_slow) if (f_past_valid && $past(state == S_IDLE) && $past(start))
        assert(busy && state != S_IDLE);

    // `valid` only fires while a request is in flight (never spuriously in IDLE).
    always @(posedge clk_slow) if (f_past_valid && valid) assert($past(state) == S_WAIT);

    // The handshake can actually complete.
    always @(posedge clk_slow) cover(valid);
`endif
endmodule
