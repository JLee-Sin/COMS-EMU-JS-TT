// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// pin_crossbar.sv - the shared pin pool (arch.md: Pinset Controller, Pin
// pool).
//
// Module: pin_crossbar
//   Owns the pads. Input path: each of the twelve physical inputs passes a
//   two-flop synchronizer (sync2), the glitch filter of depth FILTER and the
//   INVERT XOR to form pin_in[15:0]; P12-P15 and any DIR = out pin read
//   back the pinset's own driven level. Output path: for each pin the
//   owner's slot output and enable are selected by OWNER through the
//   pinsets' ROLE_MAPs, converted by DRIVE into pad level and enable, and
//   forced to the safe state when the pin is unowned or its owner is
//   invalid (P0-P7 hi-Z, P12-P15 low). Both directions are registered once.
//   The crossbar never changes ownership.
//
//   Per-pinset vectors are packed: slot_out[4p+s] is pinset p slot s,
//   role_map[16p+15:16p] is pinset p's ROLE_MAP.

`default_nettype none

module pin_crossbar (
    input  wire         clk,
    input  wire         rst_n,

    // Pads
    input  wire [11:0]  pool_in,       // P0-P11
    output wire [15:0]  pool_out,      // P0-P7 and P12-P15; [11:8] unused
    output wire [7:0]   pool_oe,       // P0-P7

    // Per-pin configuration and ownership
    input  wire [255:0] pin_cfg,
    input  wire [3:0]   valid,         // VALID per pinset

    // Pinset side
    input  wire [63:0]  role_map,      // ROLE_MAP per pinset
    input  wire [15:0]  slot_out,      // driven level per pinset slot
    input  wire [15:0]  slot_oe,       // output enable per pinset slot
    output wire [15:0]  pin_in         // synchronized, filtered, inverted pool inputs
);

endmodule
