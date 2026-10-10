// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// pin_regs.sv - the sixteen per-pin registers (arch.md: Register Bank,
// Per-pin register).
//
// Module: pin_regs
//   One 16-bit register per pool pin P0-P15: EN, DIR, DRIVE, IDLE_LVL,
//   INVERT, FILTER, OWNER ([8:7] and [0] reserved). EN and OWNER are reset
//   flops; the other fields are cfg_latch words. Written only by the Rewrite
//   FSM, whole words by pin index, and only while the pin is unowned or its
//   owner is invalid. Every field is readable in parallel by the pin
//   crossbar and the Rewrite FSM's checks.
//
//   pin_cfg is packed: bits [16p+15:16p] are pin p's word.

`default_nettype none

module pin_regs (
    input  wire         clk,
    input  wire         rst_n,

    // Write port from the Rewrite FSM
    input  wire         pin_we,
    input  wire [3:0]   pin_addr,
    input  wire [15:0]  pin_wdata,

    // Read ports
    output wire [255:0] pin_cfg,       // all sixteen words
    output wire [15:0]  pin_en,        // EN bit per pin
    output wire [31:0]  owner          // OWNER per pin, 2 bits each
);

endmodule
