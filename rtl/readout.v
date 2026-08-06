// readout.v — UART register map for the CDC corruption demo.
//
// Reading 0x00 fires the coherent handshake read AND latches a snapshot of all
// four values + the tear counters + the sample count at one instant, so a host
// can read the whole coherent set and compare:
//
//   0x00 HS        3 B  handshake read (correct)   — triggers the snapshot
//   0x01 ND        3 B  naive direct (wrong)
//   0x02 N2        3 B  naive per-bit 2-flop (still wrong)
//   0x03 GRAY      3 B  gray-coded read (correct)
//   0x04 TEAR_ND   4 B  naive-direct tear count
//   0x05 TEAR_N2   4 B  naive-2-flop  tear count
//   0x06 TEAR_GRAY 4 B  gray-path     tear count (should be ~0)
//   0x07 SAMPLES   6 B  clocks elapsed (tear-rate denominator)
//
// Host reads 0x00 first (latches), then 0x01–0x07 out of the snapshot.

module readout (
    input             clk,
    input      [7:0]  rx_data,
    input             rx_valid,
    output reg [7:0]  tx_data,
    output reg        tx_start,
    input             tx_busy,
    // coherent handshake read
    output reg        cdc_start,
    input             cdc_valid,
    input      [23:0] cdc_data,
    // live values + counters (from corrupt.v)
    input      [23:0] nd,
    input      [23:0] n2,
    input      [23:0] gray_bin,
    input      [23:0] gray_naked,
    input      [31:0] tear_nd,
    input      [31:0] tear_n2,
    input      [31:0] tear_gray,
    input      [31:0] tear_gnaked,
    input      [47:0] samples,
    output reg        active
);
    localparam [2:0] S_IDLE = 3'd0, S_HSWAIT = 3'd1,
                     S_LOAD = 3'd2, S_RISE = 3'd3, S_FALL = 3'd4;

    reg [2:0]  state = S_IDLE;
    reg [63:0] sh    = 0;
    reg [3:0]  nleft = 0;

    // coherent snapshot latched on a 0x00 read
    reg [23:0] s_hs = 0, s_nd = 0, s_n2 = 0, s_gray = 0, s_gnaked = 0;
    reg [31:0] s_tnd = 0, s_tn2 = 0, s_tgray = 0, s_tgnaked = 0;
    reg [47:0] s_samp = 0;

    always @(posedge clk) begin
        tx_start  <= 1'b0;
        cdc_start <= 1'b0;
        case (state)
            S_IDLE: begin
                active <= 1'b0;
                if (rx_valid) begin
                    active <= 1'b1;
                    case (rx_data)
                        8'h00: begin cdc_start <= 1'b1; state <= S_HSWAIT; end
                        8'h01: begin sh <= {s_nd,    40'h0}; nleft <= 4'd3; state <= S_LOAD; end
                        8'h02: begin sh <= {s_n2,    40'h0}; nleft <= 4'd3; state <= S_LOAD; end
                        8'h03: begin sh <= {s_gray,  40'h0}; nleft <= 4'd3; state <= S_LOAD; end
                        8'h04: begin sh <= {s_tnd,   32'h0}; nleft <= 4'd4; state <= S_LOAD; end
                        8'h05: begin sh <= {s_tn2,   32'h0}; nleft <= 4'd4; state <= S_LOAD; end
                        8'h06: begin sh <= {s_tgray,   32'h0}; nleft <= 4'd4; state <= S_LOAD; end
                        8'h07: begin sh <= {s_samp,    16'h0}; nleft <= 4'd6; state <= S_LOAD; end
                        8'h08: begin sh <= {s_gnaked,  40'h0}; nleft <= 4'd3; state <= S_LOAD; end
                        8'h09: begin sh <= {s_tgnaked, 32'h0}; nleft <= 4'd4; state <= S_LOAD; end
                        default: active <= 1'b0;
                    endcase
                end
            end

            S_HSWAIT: if (cdc_valid) begin
                // latch the whole coherent snapshot at this instant
                s_hs   <= cdc_data; s_nd <= nd; s_n2 <= n2; s_gray <= gray_bin;
                s_gnaked <= gray_naked;
                s_tnd  <= tear_nd;  s_tn2 <= tear_n2; s_tgray <= tear_gray;
                s_tgnaked <= tear_gnaked;
                s_samp <= samples;
                sh     <= {cdc_data, 40'h0};   // send HS now
                nleft  <= 4'd3;
                state  <= S_LOAD;
            end

            S_LOAD: if (!tx_busy) begin
                tx_data  <= sh[63:56];
                tx_start <= 1'b1;
                state    <= S_RISE;
            end
            S_RISE: if (tx_busy) state <= S_FALL;
            S_FALL: if (!tx_busy) begin
                sh <= {sh[55:0], 8'h00};
                if (nleft == 4'd1) begin active <= 1'b0; state <= S_IDLE; end
                else begin nleft <= nleft - 4'd1; state <= S_LOAD; end
            end
            default: state <= S_IDLE;
        endcase
    end
endmodule
