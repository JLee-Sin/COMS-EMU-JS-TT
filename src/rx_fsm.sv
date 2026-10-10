// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// rx_fsm.sv - the receive pipeline (arch.md: Translation FSM). One per
// pinset.
//
// Module: rx_fsm
//   Stages 4-7 of the receive pipeline around an RX sequencer: line decode
//   (NRZ, NRZI, Manchester) and the destuffer, the CRC register (crc_reg),
//   the parity accumulator, the deserializer with BIT_ORDER, the SAMPLE /
//   MATCH_IMM / MATCH_ADDR flags, and output staging, which opens a message
//   on FRAME_BEGIN with a header snapshot, emits bytes on EMIT and closes
//   it on FRAME_END. Implements the op_fire strobes from its sequencer and
//   returns the datapath flags. Stages 1-3 (slot mux, event detector, bit
//   timer) live in pinset.sv and primitives.sv and feed this module.
//
//   The sequencer runs the RX program at prog_base = 0x70*PROTO + 0x38
//   from VALID rising until it falls.

`default_nettype none

module rx_fsm #(
    parameter int FULL_PROTOCOLS = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire        rx_abort,       // from the Rewrite FSM

    // Pinset register, read live
    input  wire [63:0] ps_reg,

    // Slot inputs and events
    input  wire        din,            // slot RX_SLOT, after the slot mux
    input  wire        sel_level,
    input  wire        sample_tick,
    input  wire        manch_bit,
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

    // Shared with tx_fsm
    input  wire        peer_in,
    output wire        peer_out,
    output wire        rw_set,         // MATCH_ADDR captured RW
    output wire        rw_val,
    input  wire        held,

    // Timer control
    output wire        timer_sync,

    // Output staging to the pinset's GUI buffer and the memory FIFO
    output wire        msg_begin,      // header snapshot now
    output wire        msg_end,
    output wire        emit,
    output wire [7:0]  emit_byte,
    output wire        msg_err,        // error flag of the open message
    output wire        msg_truncated,

    // Instruction fetch
    output wire        pm_req,
    output wire [8:0]  pm_addr,
    input  wire [15:0] pm_rdata,
    input  wire        pm_ack
);

endmodule
