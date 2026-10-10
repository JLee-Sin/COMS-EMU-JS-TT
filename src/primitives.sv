// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// primitives.sv - small shared building blocks used by the pin pool and
// the pinsets. None of them knows any protocol.
//
// Modules:
//   sync2         Two-flop synchronizer. Every external signal passes one
//                 before any logic (arch.md: Design principles).
//   glitch_filter Glitch filter of depth 0-15 cycles after the synchronizer
//                 (arch.md: I/O, Pad mapping, FILTER).
//   event_det     One per pinset. Turns the slot signals into one-cycle
//                 pulses: DIN rise / fall / edge, CLK rise / fall, SEL on /
//                 off, START, STOP, SE0. A slot whose per-pin word is 0x0000
//                 reads as 1 and produces no events (arch.md: Translation
//                 FSM, stage 2).
//   bit_timer     One per pinset. Produces the sample tick (RX) and drive
//                 tick (TX) from the internal divider, the CLK slot edges
//                 (CLKED) or Manchester interval measurement, plus the
//                 idle-time count in bit times; drives the CLK slot under
//                 CLK_RUN (arch.md: Translation FSM, stage 3; Transmission
//                 FSM, stage 6).
//   crc_reg       Right-shifting reflected CRC register covering CRC5,
//                 CRC16 and CRC32, with residue compare (arch.md:
//                 Translation FSM, stage 5).

`default_nettype none

module sync2 (
    input  wire clk,
    input  wire d,
    output wire q
);

endmodule


module glitch_filter (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] depth,        // FILTER, 0 = off
    input  wire       d,
    output wire       q
);

endmodule


module event_det (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,       // VALID
    input  wire [3:0] slot_in,      // s0 DOUT, s1 DIN (post RX_SLOT), s2 CLK, s3 SEL
    input  wire [3:0] slot_mapped,  // per-pin word not 0x0000

    output wire       din_rise,
    output wire       din_fall,
    output wire       din_edge,
    output wire       clk_rise,
    output wire       clk_fall,
    output wire       sel_on,
    output wire       sel_off,
    output wire       start_ev,     // DIN falls while CLK high
    output wire       stop_ev,      // DIN rises while CLK high
    output wire       se0           // s0 and s1 both low
);

endmodule


module bit_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,      // VALID

    // Configuration, read live from the pinset register
    input  wire [15:0] bit_div,
    input  wire [1:0]  line_code,   // NRZ, NRZI, Manchester
    input  wire        clked,       // ticks from the CLK slot
    input  wire        cpol,
    input  wire        cpha,

    // Events and levels
    input  wire        clk_rise,
    input  wire        clk_fall,
    input  wire        sel_on,
    input  wire        sel_level,   // SEL asserted now
    input  wire        din_edge,
    input  wire        din_level,
    input  wire        start_ev,
    input  wire        stop_ev,

    // Sequencer control
    input  wire        timer_sync,  // TIMER_SYNC: reload to half a bit
    input  wire        clk_run,     // CLK_RUN / CLK_STOP level
    input  wire        clk_force,   // CLK_0 / CLK_1 active
    input  wire        clk_force_lvl,

    // Ticks
    output wire        sample_tick, // to the RX sequencer
    output wire        drive_tick,  // to the TX sequencer
    output wire        manch_bit,   // decoded bit with sample_tick when Manchester
    output wire [5:0]  idle_bits,   // bit times since the last DIN edge, saturating
    output wire        clk_out      // level for the CLK slot
);

endmodule


module crc_reg (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  sel,         // CRC_NONE, CRC_5, CRC_16, CRC_32
    input  wire        init,        // reset to all ones
    input  wire        shift_in,    // consume one data bit
    input  wire        bit_in,
    input  wire        shift_out,   // emit one CRC bit
    output wire        bit_out,
    output wire        residue_ok   // register equals the width's residue
);

endmodule
