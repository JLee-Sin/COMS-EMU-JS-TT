// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// pinset.sv - one emulation channel (arch.md: Pinset Controller, Pinset
// instance). Four instances.
//
// Module: pinset
//   Holds the 64-bit pinset register (cfg_latch words, VALID a reset flop),
//   the slot muxes that pick s0-s3 from pin_in by ROLE_MAP, the event
//   detector and bit timer (primitives.sv), rx_fsm and tx_fsm each with its
//   sequencer, the PEER / RW / HELD flags shared between them, the GUI
//   record buffer with its header snapshot (latch-based) and the dump
//   enable and status flops. The TX buffer lives in tx_fsm.
//
//   Parameter FULL_PROTOCOLS = 0 removes the Manchester encoder and
//   decoder, the interval classifier, the destuffer and the CRC32 taps as
//   the first area mitigation; every instance currently sets it to 1.
//
//   Two sequencers fetch through pm_req[0] (TX) and pm_req[1] (RX).

`default_nettype none

module pinset #(
    parameter int FULL_PROTOCOLS = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    // Pin pool
    input  wire [15:0] pin_in,
    output wire [3:0]  slot_out,
    output wire [3:0]  slot_oe,
    output wire [15:0] role_map,

    // Pinset register, read by the crossbar and the Controller
    output wire        valid,
    output wire [2:0]  proto,
    output wire        master,

    // From the Controller
    input  wire        tx_load,
    input  wire [3:0]  tx_len,
    input  wire [63:0] tx_data,
    input  wire        tx_hold,
    input  wire        tx_persist,
    input  wire        gui_en,
    input  wire        mem_en,

    // From the Rewrite FSM
    input  wire        rx_abort,
    input  wire        buf_flush,
    input  wire        valid_clr,
    input  wire        ps_we,
    input  wire [1:0]  ps_word,
    input  wire [15:0] ps_wdata,

    // Status
    output wire        tx_busy,
    output wire        tx_lock,
    output wire        rx_ovf,

    // To the GUI Output Controller
    output wire        gui_rec_valid,
    output wire [23:0] gui_hdr,
    output wire [63:0] gui_data,
    output wire [3:0]  gui_len,
    output wire [1:0]  gui_flags,      // {error, truncated}
    input  wire        gui_rec_take,

    // To the Memory Output Controller
    output wire        mem_push,
    output wire [10:0] mem_entry,      // {end, error, truncated, byte}

    // Protocol memory port, one request line per sequencer
    output wire [1:0]  pm_req,
    output wire [17:0] pm_addr,        // {rx_addr, tx_addr}
    input  wire [15:0] pm_rdata,
    input  wire [1:0]  pm_ack
);

endmodule
