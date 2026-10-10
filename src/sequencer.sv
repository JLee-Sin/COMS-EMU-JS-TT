// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// sequencer.sv - the program interpreter (arch.md: Sequencer). Two
// instances per pinset, one in rx_fsm and one in tx_fsm.
//
// Module: sequencer
//   Fetches 16-bit instructions from the protocol memory through its own
//   request line, with the next sequential instruction prefetched while the
//   current one executes. Executes the three formats: ACT waits for an
//   event then fires an operation CNT times, IMM loads a constant, BR
//   branches on a flag. Keeps the PC, repeat counter, byte counter and the
//   flags S, MATCH, ZERO, ENDF, ERR; evaluates the ENDS frame-end set;
//   runs STREAM_OUT / STREAM_IN internally so byte streams need no fetch.
//   Operations that touch the datapath are issued as op_fire / op_code
//   strobes and implemented by the enclosing rx_fsm or tx_fsm, which
//   returns the datapath flags. Knows nothing about any protocol.
//
//   Parameter IS_TX selects which operations and events are wired; the
//   rest execute as NOP. With prog_base selecting PROTO 7 the built-in RAW
//   program is read from constants instead of memory.

`default_nettype none

module sequencer #(
    parameter bit IS_TX = 1'b1
) (
    input  wire        clk,
    input  wire        rst_n,

    // Run control
    input  wire        start,          // TX: tx_load. RX: VALID rising
    input  wire        stop,           // VALID low, buf_flush, rx_abort
    input  wire        persist,        // TX target: re-arm at END
    input  wire        is_master,      // MASTER
    input  wire [8:0]  prog_base,      // 0x70*PROTO (+0x38 for RX)
    input  wire        raw_mode,       // PROTO = 7, built-in program
    output wire        running,
    output wire        ended,          // END executed, one cycle
    output wire        lock,           // LOCK executed since start
    output wire        held_set,       // END with hold bit

    // Instruction fetch
    output wire        pm_req,
    output wire [8:0]  pm_addr,
    input  wire [15:0] pm_rdata,
    input  wire        pm_ack,

    // Configuration for CNT decoding
    input  wire [3:0]  data_bits,      // DATA_BITS field
    input  wire        stop2,          // STOP field means 2 bits
    input  wire        parity_none,    // PARITY_OUT / PARITY_CHECK skip their wait
    input  wire [1:0]  crc_sel,        // for CRC_LEN

    // Events from event_det and bit_timer
    input  wire        tick,           // sample tick (RX) or drive tick (TX)
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
    input  wire        peer_in,        // SIGNAL from the other sequencer
    output wire        peer_out,

    // Levels and flags from the datapath
    input  wire        sel_level,
    input  wire        din_level,
    input  wire        flag_s,         // last SAMPLE / PARITY_CHECK
    input  wire        flag_match,
    input  wire        flag_empty,
    input  wire        flag_err,
    input  wire        flag_hold,      // TRANSMIT HOLD
    input  wire        flag_held,
    input  wire        flag_rw,
    input  wire        bit0,           // B0 of current byte / word
    input  wire        bit1,
    input  wire [7:0]  cur_byte,       // for LOAD_COUNT

    // Operations to the datapath
    output wire        op_fire,        // one cycle per executed ACT op
    output wire [4:0]  op_code,
    output wire        imm_fire,
    output wire [3:0]  imm_code,
    output wire [7:0]  imm_val
);

endmodule
