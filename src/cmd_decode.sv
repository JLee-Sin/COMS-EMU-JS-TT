// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// cmd_decode.sv - command decoder and status register (arch.md: Controller,
// Decoder).
//
// Module: cmd_decode
//   On cs_rise, validates the frame in the command buffer (byte count
//   against OP, no partial byte, no overflow, OP not reserved, TRANSMIT N
//   against the byte count) and dispatches: SET_PROTO and RELEASE to the
//   Rewrite FSM, DUMP_CTRL to the enable flops, TRANSMIT to a pinset in one
//   cycle, MEM_RESET to dump_mem, WRITE_MEM as four port writes after the
//   in-use check, READ_MEM as a block fetch during the frame. Keeps the
//   status byte and the READ_STATUS snapshot taken on cs_fall.
//
//   The payload is never interpreted; protocol rules live in the programs.

`default_nettype none

module cmd_decode (
    input  wire        clk,
    input  wire        rst_n,

    // From host_spi
    input  wire        cs_fall,
    input  wire        cs_rise,
    input  wire        byte_done,
    input  wire [3:0]  byte_cnt,
    input  wire        bit_misaligned,
    input  wire        overflow,
    input  wire [79:0] cmd_buf,

    // To host_spi
    output wire [7:0]  status,
    output wire        miso_load,
    output wire [7:0]  miso_data,

    // Request to the Rewrite FSM
    output wire        rw_req,
    output wire        rw_op,
    output wire [1:0]  rw_ps,
    output wire [2:0]  rw_tmpl,
    output wire        rw_ovr,
    output wire        rw_kind,
    output wire [15:0] rw_val,
    output wire [3:0]  rw_offset,
    input  wire        rw_busy,
    input  wire        rw_done,
    input  wire [1:0]  rw_err,

    // TRANSMIT to the pinsets
    output wire [3:0]  tx_load,
    output wire [3:0]  tx_len,
    output wire [63:0] tx_data,
    output wire        tx_hold,
    output wire        tx_persist,

    // Dump control
    output wire [3:0]  gui_en,
    output wire [3:0]  mem_en,
    output wire        mem_reset,

    // Protocol memory port
    output wire        pm_req,
    output wire        pm_we,
    output wire [8:0]  pm_addr,
    output wire [15:0] pm_wdata,
    input  wire [15:0] pm_rdata,
    input  wire        pm_ack,

    // Status inputs
    input  wire [3:0]  valid,
    input  wire [3:0]  tx_busy,
    input  wire [3:0]  tx_lock,
    input  wire [3:0]  rx_ovf,
    input  wire [11:0] proto,
    input  wire [3:0]  master,
    input  wire        dump_pending,
    input  wire [15:0] owned
);

endmodule
