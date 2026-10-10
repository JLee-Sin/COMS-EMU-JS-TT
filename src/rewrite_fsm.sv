// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// rewrite_fsm.sv - the only writer of the register bank (arch.md: Rewrite
// FSM).
//
// Module: rewrite_fsm
//   One instance shared by all pinsets. For SET_PROTO it reads a template
//   from the protocol memory through the shared port, checks it (PROTO
//   4-6 rejected, pin conflicts, pin capabilities), invalidates the pinset,
//   flushes it, releases pins no longer used, re-reads and writes the
//   per-pin words, then writes the pinset register words 4-7 with the pin
//   offset and the host-chosen override patched in, VALID last. For RELEASE
//   it invalidates, flushes and clears ownership. A rejected request writes
//   nothing. States: IDLE, CHECK, INVALIDATE, FLUSH, SETTLE, RELEASE_PINS,
//   WRITE_PINS, WRITE_CHANNEL, DONE.
//
//   It holds no template words between states, only each slot's enable
//   bit and target pin.

`default_nettype none

module rewrite_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // Request from the Controller
    input  wire        rw_req,
    input  wire        rw_op,          // 0 SET_PROTO, 1 RELEASE
    input  wire [1:0]  rw_ps,
    input  wire [2:0]  rw_tmpl,
    input  wire        rw_ovr,
    input  wire        rw_kind,        // 0 BIT_DIV, 1 ADDR
    input  wire [15:0] rw_val,
    input  wire [3:0]  rw_offset,
    output wire        rw_busy,
    output wire        rw_done,        // one-cycle pulse
    output wire [1:0]  rw_err,         // valid with rw_done; 0 = success

    // Protocol memory port, reads only
    output wire        pm_req,
    output wire [8:0]  pm_addr,        // 0x1C0 + 8*template + word
    input  wire [15:0] pm_rdata,
    input  wire        pm_ack,

    // Per-pin register write port
    output wire        pin_we,
    output wire [3:0]  pin_addr,
    output wire [15:0] pin_wdata,

    // Pinset register write port, 16 bits at a time
    output wire        ps_we,
    output wire [1:0]  ps_sel,         // pinset
    output wire [1:0]  ps_word,        // 0-3 = template words 4-7
    output wire [15:0] ps_wdata,
    output wire [3:0]  valid_clr,      // clears VALID ahead of writes

    // To the pinsets
    output wire [3:0]  rx_abort,
    output wire [3:0]  buf_flush,

    // For the checks
    input  wire [15:0] pin_en,
    input  wire [31:0] owner,          // {owner[15], ..., owner[0]}, 2 bits each
    input  wire [3:0]  tx_lock
);

endmodule
