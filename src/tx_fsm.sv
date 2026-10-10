// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// tx_fsm.sv - the transmit pipeline (arch.md: Transmission FSM). One per
// pinset.
//
// Module: tx_fsm
//   The latch-based 8-byte TX buffer with its read pointer and FILL
//   underflow, and stages 2-5 and 7 of the transmit pipeline around a TX
//   sequencer: the serializer with BIT_ORDER (loaded by NEXT_BYTE or
//   LOAD_IMM), the parity accumulator and CRC register (crc_reg), the bit
//   stuffer, the line encoder (NRZ, NRZI, Manchester) and the pin driver
//   that routes the bit to DOUT (and its complement to slot 1 when
//   differential), honours DRIVE_0 / DRIVE_1 / DRIVE_IDLE / SAMPLE, and
//   drives SEL and CLK. Stage 6 (bit timer) is in primitives.sv and feeds
//   this module. Produces tx_busy and tx_lock (arch.md: Busy and lock).
//
//   The sequencer runs the TX program at prog_base = 0x70*PROTO from
//   tx_load until END; with PERSIST in a target it rewinds and re-arms.

`default_nettype none

module tx_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire        buf_flush,      // from the Rewrite FSM

    // Pinset register, read live
    input  wire [63:0] ps_reg,

    // TRANSMIT from the Controller
    input  wire        tx_load,
    input  wire [3:0]  tx_len,
    input  wire [63:0] tx_data,
    input  wire        tx_hold,
    input  wire        tx_persist,
    output wire        tx_busy,
    output wire        tx_lock,

    // Events and timing
    input  wire        din,            // slot 1, for SAMPLE
    input  wire        sel_level,
    input  wire        drive_tick,
    input  wire        sample_tick,    // SAMPLE captures here
    input  wire        din_rise,
    input  wire        din_fall,
    input  wire        din_edge,
    input  wire        clk_rise,
    input  wire        clk_fall,
    input  wire        sel_on,
    input  wire        sel_off,
    input  wire        start_ev,
    input  wire        stop_ev,
    input  wire        se0,
    input  wire [5:0]  idle_bits,

    // Shared with rx_fsm
    input  wire        peer_in,
    output wire        peer_out,
    input  wire        rw,
    output wire        held,           // bus left held by END

    // Timer and clock control to bit_timer
    output wire        clk_run,
    output wire        clk_force,
    output wire        clk_force_lvl,

    // Slot drivers to the crossbar
    output wire [3:0]  slot_out,       // s0 DOUT, s1 complement, s2 CLK, s3 SEL
    output wire [3:0]  slot_oe,

    // Instruction fetch
    output wire        pm_req,
    output wire [8:0]  pm_addr,
    input  wire [15:0] pm_rdata,
    input  wire        pm_ack
);

endmodule
