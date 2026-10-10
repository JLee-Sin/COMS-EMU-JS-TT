// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// controller.sv - top file of the Controller (arch.md: IPs, Controller).
//
// Module: controller
//   Wiring only. Instantiates host_spi (SPI receiver, command buffer, MISO)
//   and cmd_decode (frame validation on CS_n rise, dispatch, status
//   register, WRITE_MEM / READ_MEM) and exposes the Controller's interfaces
//   to protoemu_top: the request bus to the Rewrite FSM, TRANSMIT payload
//   and dump enables to the pinsets, the memory-output reset, the protocol
//   memory port, and the status inputs from the rest of the chip.
//
//   Vectors indexed per pinset are packed four wide: bit p, or bits
//   [3p+2:3p] for proto, belong to pinset p.

`default_nettype none

module controller (
    input  wire        clk,
    input  wire        rst_n,

    // Host SPI pins
    input  wire        host_sck,
    input  wire        host_mosi,
    input  wire        host_cs_n,
    output wire        host_miso,

    // Request to the Rewrite FSM
    output wire        rw_req,
    output wire        rw_op,          // 0 SET_PROTO, 1 RELEASE
    output wire [1:0]  rw_ps,
    output wire [2:0]  rw_tmpl,
    output wire        rw_ovr,         // override present
    output wire        rw_kind,        // 0 BIT_DIV, 1 ADDR
    output wire [15:0] rw_val,
    output wire [3:0]  rw_offset,
    input  wire        rw_busy,
    input  wire        rw_done,
    input  wire [1:0]  rw_err,

    // TRANSMIT to the pinsets
    output wire [3:0]  tx_load,        // one-cycle strobe per pinset
    output wire [3:0]  tx_len,         // 1-8
    output wire [63:0] tx_data,        // payload, byte 0 in [63:56]
    output wire        tx_hold,
    output wire        tx_persist,

    // Dump control
    output wire [3:0]  gui_en,
    output wire [3:0]  mem_en,
    output wire        mem_reset,

    // Protocol memory port (WRITE_MEM writes, READ_MEM reads)
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
    input  wire [11:0] proto,          // {proto[3], proto[2], proto[1], proto[0]}
    input  wire [3:0]  master,
    input  wire        dump_pending,
    input  wire [15:0] owned
);

endmodule
