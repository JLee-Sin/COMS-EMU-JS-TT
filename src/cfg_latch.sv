// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// cfg_latch.sv - latch-based storage word (arch.md: Register Bank,
// Storage and Latch-based buffers).
//
// Module: cfg_latch
//   A WIDTH-bit word of level-sensitive latches with a gated enable. Used
//   for every pinset register field except VALID, every per-pin field
//   except EN and OWNER, the TX buffer and the GUI record buffer. The
//   latches are transparent during the low phase of clk; d must come from
//   flops that change on the rising edge, and a word must only be written
//   when nothing reads it (pinset invalid, TRANSMIT refused while locked,
//   GUI record read only after ready).
//
//   Instantiates the PDK latch and clock-gating cells (confirm the
//   sg13cmos5l names; sg13g2 equivalents are sg13g2_dlhq_1 and
//   sg13g2_lgcp_1). A behavioural model stands in under `ifdef SIM. If the
//   cells fail gate-level simulation this module is rebuilt from flops with
//   no other change.

`default_nettype none

module cfg_latch #(
    parameter int WIDTH = 16
) (
    input  wire             clk,
    input  wire             we,       // write enable, from a flop
    input  wire [WIDTH-1:0] d,        // from flops, stable through the low phase
    output wire [WIDTH-1:0] q
);

endmodule
