// uart_tx.v — 8N1 UART transmitter, reusable core.
//
// Sends one byte: start bit (low), 8 data bits LSB-first, stop bit (high, the
// idle level). Pulse `start` while `busy` is low to begin; `data` is latched at
// that instant, so the caller need not hold it. `busy` stays high until the
// stop bit completes. Parameterized by CLKS_PER_BIT = clk / baud (104 @ 12 MHz).
//
// tx is entirely in the clk domain (the host resynchronizes to our edges), so
// unlike the receiver there is no CDC here — the byte simply clocks out one
// bit period at a time.

module uart_tx #(
    parameter integer CLKS_PER_BIT = 104
) (
    input        clk,
    input        start,          // pulse to begin; ignored while busy
    input  [7:0] data,
    output reg   tx   = 1'b1,     // serial out; idle high
    output reg   busy = 1'b0
);
    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    // Size the terminal count to the counter width so the comparison doesn't mix
    // a narrow reg with a 32-bit integer literal.
    localparam integer  CW   = $clog2(CLKS_PER_BIT);
    localparam integer LAST = CLKS_PER_BIT - 1;   // end of a bit period

    reg [CW-1:0] clk_cnt = 0;
    reg [2:0]    bit_idx = 0;
    reg [7:0]    shreg   = 8'h00;
    reg [1:0]    state   = S_IDLE;

    always @(posedge clk) begin
        case (state)
            S_IDLE: begin
                tx      <= 1'b1;
                busy    <= 1'b0;
                clk_cnt <= 0;
                bit_idx <= 0;
                if (start) begin
                    shreg <= data;
                    busy  <= 1'b1;
                    tx    <= 1'b0;      // drive the start bit
                    state <= S_START;
                end
            end

            S_START: begin             // hold the start bit for one bit period
                if (clk_cnt == LAST[CW-1:0]) begin
                    clk_cnt <= 0;
                    tx      <= shreg[0];    // first data bit (LSB)
                    state   <= S_DATA;
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            S_DATA: begin              // one bit period per data bit
                if (clk_cnt == LAST[CW-1:0]) begin
                    clk_cnt <= 0;
                    if (bit_idx == 3'd7) begin
                        tx    <= 1'b1;      // stop bit (idle level)
                        state <= S_STOP;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        tx      <= shreg[bit_idx + 1];
                    end
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            S_STOP: begin              // hold stop bit one bit period, then done
                if (clk_cnt == LAST[CW-1:0]) begin
                    clk_cnt <= 0;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end else clk_cnt <= clk_cnt + 1'b1;
            end

            default: state <= S_IDLE;
        endcase
    end
endmodule
