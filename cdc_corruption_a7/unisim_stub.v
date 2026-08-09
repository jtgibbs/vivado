// unisim_stub.v — minimal behavioral stand-ins for the two Xilinx primitives
// this design instantiates, so the whole thing elaborates and runs under Icarus
// on a machine with no Vivado.
//
// FOR THE LOCAL SMOKE TEST ONLY (`make smoke`). Never read by run.tcl — the
// Vivado flows use the real unisims_ver / simprims_ver libraries.
//
// The point of this file is cost, not fidelity. EC2 time and Vivado runs are
// slow and remote; a testbench bug is neither. The first version of
// tb_cdc_corruption.sv lost every reply byte after the first read, because the
// DUT starts transmitting one bit time before the host finishes its frame — a
// full-duplex race that has nothing to do with Xilinx, Artix-7, or timing
// annotation, and that would have burned a round trip to the instance to find.
// Catch that class of bug here for free; go to the instance for the ones that
// genuinely need it.
//
// What these stubs do NOT model: anything that matters. No delays, no timing
// checks, no GSR. `make smoke` therefore reports zero tears by construction, as
// every behavioral simulation of this design must.

`timescale 1ns / 1ps

module BUFG (input I, output O);
    assign O = I;
endmodule

module STARTUPE2 #(
    parameter      PROG_USR      = "FALSE",
    parameter real SIM_CCLK_FREQ = 0.0
) (
    output CFGCLK, output CFGMCLK, output EOS, output PREQ,
    input  CLK, input GSR, input GTS, input KEYCLEARB, input PACK,
    input  USRCCLKO, input USRCCLKTS, input USRDONEO, input USRDONETS
);
    // ~65 MHz nominal, the CFGMCLK ring oscillator's typical rate.
    reg mclk = 1'b0;
    always #7.6895 mclk = ~mclk;
    assign CFGMCLK = mclk;
    assign CFGCLK  = 1'b0;
    assign EOS     = 1'b1;
    assign PREQ    = 1'b0;
endmodule
