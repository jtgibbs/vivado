// uart_rx.v — 8N1 UART receiver, reusable core.
//
// Receives one byte (8 data bits, no parity, 1 stop bit — "8N1") and pulses
// `valid` high for one clock with the byte on `data`. Parameterized by
// CLKS_PER_BIT = clk frequency / baud rate (104 for 12 MHz / 115200).
//
// CDC note: `rx` is asynchronous to `clk` — it's a pin driven by the host's
// UART, in an unrelated clock domain. It is passed through a two-flop
// synchronizer before the state machine samples it. A single flop would let a
// metastable value propagate into the FSM state and corrupt framing; two flops
// give the first one a full clock to resolve. This is the same discipline the
// CDC experiments later formalize — here it is load-bearing already.
//
// Sampling: the receiver finds the falling edge of the start bit, waits half a
// bit period to reach the *center* of the start bit and confirms it is still
// low (rejects glitches), then samples each data bit at its center, one bit
// period apart. Center sampling is what tolerates the small baud-rate mismatch:
// error accumulates across the frame but stays well under half a bit.

module uart_rx #(
    parameter integer CLKS_PER_BIT = 104
) (
    input            clk,
    input            rx,          // asynchronous serial in (idle high)
    output reg [7:0] data  = 8'h00,
    output reg       valid = 1'b0 // 1-clock strobe: `data` is fresh
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3,
                     S_DONE  = 3'd4;

    // Two-flop synchronizer for the async rx line. Init high = line idle.
    reg rx_meta = 1'b1, rx_sync = 1'b1;
    always @(posedge clk) {rx_sync, rx_meta} <= {rx_meta, rx};

    // Bit-period timing. Size the terminal counts to the counter width so the
    // comparisons don't mix a narrow reg with a 32-bit integer literal.
    localparam integer CW   = $clog2(CLKS_PER_BIT);
    localparam integer MID  = (CLKS_PER_BIT - 1) / 2;   // center of a bit
    localparam integer LAST = CLKS_PER_BIT - 1;         // end of a bit period

    reg [CW-1:0] clk_cnt = 0;
    reg [2:0]    bit_idx = 0;
    reg [2:0]    state   = S_IDLE;

    always @(posedge clk) begin
        valid <= 1'b0;                          // default; asserted 1 cycle in S_DONE
        case (state)
            S_IDLE: begin
                clk_cnt <= 0;
                bit_idx <= 0;
                if (rx_sync == 1'b0) state <= S_START;   // start-bit edge seen
            end

            S_START: begin                      // walk to the center of the start bit
                if (clk_cnt == MID[CW-1:0]) begin
                    if (rx_sync == 1'b0) begin  // still low -> genuine start
                        clk_cnt <= 0;
                        state   <= S_DATA;
                    end else begin
                        state   <= S_IDLE;      // glitch -> abandon
                    end
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            S_DATA: begin                       // sample each data bit at its center
                if (clk_cnt == LAST[CW-1:0]) begin
                    clk_cnt        <= 0;
                    data[bit_idx]  <= rx_sync;  // LSB first
                    if (bit_idx == 3'd7) state <= S_STOP;
                    else               bit_idx <= bit_idx + 1'b1;
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            S_STOP: begin                       // one bit period of stop, then flag
                if (clk_cnt == LAST[CW-1:0]) begin
                    clk_cnt <= 0;
                    valid   <= 1'b1;
                    state   <= S_DONE;
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            S_DONE: state <= S_IDLE;            // valid was high this cycle; drop it

            default: state <= S_IDLE;
        endcase
    end
endmodule
