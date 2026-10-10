// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// pe_pkg.sv - shared constants for the protocol emulator.
//
// Package: pe_pkg
//   Host op codes and status error codes (arch.md: OpCodes), the protocol
//   memory map (Protocol Memory), pinset and per-pin register field positions
//   (Register Bank), the sequencer instruction encodings (Sequencer) and the
//   CRC residues (Translation FSM, stage 5).
//
//   Modules read these as pe_pkg::NAME. Nothing imports the package
//   wholesale, so the Yosys SystemVerilog subset is not stretched.
//   This file must be listed first in info.yaml and test/Makefile.

`default_nettype none

package pe_pkg;

  // ---------------------------------------------------------------- Host port
  // Header byte: [7:4] OP, [3:2] PS, [1:0] SUB.
  localparam logic [3:0] OP_NOP         = 4'h0;
  localparam logic [3:0] OP_SET_PROTO   = 4'h1;
  localparam logic [3:0] OP_DUMP_CTRL   = 4'h2;
  localparam logic [3:0] OP_TRANSMIT    = 4'h3;
  localparam logic [3:0] OP_READ_STATUS = 4'h4;
  localparam logic [3:0] OP_RELEASE     = 4'h5;
  localparam logic [3:0] OP_MEM_RESET   = 4'h6;
  localparam logic [3:0] OP_WRITE_MEM   = 4'h7;
  localparam logic [3:0] OP_READ_MEM    = 4'h8;   // 0x9-0xF reserved

  // Status byte [6:5]
  localparam logic [1:0] ERR_BAD_FRAME    = 2'b00;
  localparam logic [1:0] ERR_PIN_CONFLICT = 2'b01;
  localparam logic [1:0] ERR_INCAPABLE    = 2'b10;
  localparam logic [1:0] ERR_BUSY         = 2'b11;

  localparam int CMD_BUF_BYTES = 10;               // longest legal frame

  // --------------------------------------------------------- Protocol memory
  // 512 x 16-bit words, 9-bit word address, 4-word blocks.
  localparam int PM_WORDS      = 512;
  localparam int PM_ADDR_W     = 9;
  localparam int PM_BLOCKS     = 128;
  localparam int NUM_SLOTS     = 4;                // protocol slots 0-3
  localparam int SLOT_WORDS    = 112;              // 2 programs x 56
  localparam int PROG_WORDS    = 56;               // instructions per direction
  localparam int NUM_TEMPLATES = 8;
  localparam int TMPL_WORDS    = 8;
  localparam logic [PM_ADDR_W-1:0] TMPL_BASE = 9'h1C0;
  localparam logic [2:0] PROTO_RAW = 3'd7;         // built in, reads no memory

  // Program base for slot s: TX at 0x70*s, RX at 0x70*s + 0x38.
  localparam int RX_PROG_OFFSET = 56;

  // ---------------------------------------------- Pinset register, 64 bits
  localparam int PS_VALID     = 63;
  localparam int PS_PROTO_H   = 62, PS_PROTO_L    = 60;
  localparam int PS_MASTER    = 59;
  localparam int PS_LINE_H    = 58, PS_LINE_L     = 57;
  localparam int PS_BITDIV_H  = 56, PS_BITDIV_L   = 41;
  localparam int PS_DBITS_H   = 40, PS_DBITS_L    = 37;
  localparam int PS_PARITY_H  = 36, PS_PARITY_L   = 35;
  localparam int PS_STOP_H    = 34, PS_STOP_L     = 33;
  localparam int PS_BITORDER  = 32;
  localparam int PS_BITSTUFF  = 31;
  localparam int PS_CRC_H     = 30, PS_CRC_L      = 29;
  localparam int PS_CPOL      = 28;
  localparam int PS_CPHA      = 27;
  localparam int PS_RXSLOT_H  = 26, PS_RXSLOT_L   = 25;
  localparam int PS_FILL      = 24;
  localparam int PS_ADDR_H    = 23, PS_ADDR_L     = 17;
  localparam int PS_CLKED     = 16;
  localparam int PS_ROLEMAP_H = 15, PS_ROLEMAP_L  = 0;

  localparam logic [1:0] LINE_NRZ = 2'b00, LINE_NRZI = 2'b01, LINE_MANCHESTER = 2'b10;
  localparam logic [1:0] CRC_NONE = 2'b00, CRC_5 = 2'b01, CRC_16 = 2'b10, CRC_32 = 2'b11;

  // ----------------------------------------------- Per-pin register, 16 bits
  localparam int PIN_EN       = 15;
  localparam int PIN_DIR_H    = 14, PIN_DIR_L    = 13;
  localparam int PIN_DRIVE_H  = 12, PIN_DRIVE_L  = 11;
  localparam int PIN_IDLE     = 10;
  localparam int PIN_INVERT   = 9;                 // [8:7] reserved
  localparam int PIN_FILTER_H = 6,  PIN_FILTER_L = 3;
  localparam int PIN_OWNER_H  = 2,  PIN_OWNER_L  = 1;

  localparam logic [1:0] DIR_IN = 2'b00, DIR_OUT = 2'b01, DIR_BIDIR = 2'b10;
  localparam logic [1:0] DRV_PUSHPULL = 2'b00, DRV_OPENDRAIN = 2'b01,
                         DRV_DIFF = 2'b10, DRV_HIZ = 2'b11;

  // ------------------------------------------------- Sequencer instructions
  // [15:14] format
  localparam logic [1:0] FMT_ACT = 2'b00;          // [13:10] WAIT [9:5] OP [4:0] CNT
  localparam logic [1:0] FMT_IMM = 2'b01;          // [13:10] IOP  [7:0] IMM
  localparam logic [1:0] FMT_BR  = 2'b10;          // [13:9]  COND [5:0] TARGET

  localparam logic [15:0] INSTR_END_PAD = 16'h03E0; // ACT NONE END, program padding

  // WAIT codes
  localparam logic [3:0] W_NONE = 4'd0,  W_TICK = 4'd1,   W_DIN_RISE = 4'd2,
                         W_DIN_FALL = 4'd3, W_DIN_EDGE = 4'd4, W_CLK_RISE = 4'd5,
                         W_CLK_FALL = 4'd6, W_SEL_ON = 4'd7, W_SEL_OFF = 4'd8,
                         W_START = 4'd9, W_STOP = 4'd10, W_SE0 = 4'd11,
                         W_IDLE = 4'd12, W_PEER = 4'd13;

  // ACT ops
  localparam logic [4:0] O_NOP = 5'd0,  O_DRIVE_0 = 5'd1,   O_DRIVE_1 = 5'd2,
                         O_DRIVE_IDLE = 5'd3, O_SHIFT_OUT = 5'd4, O_SHIFT_IN = 5'd5,
                         O_SAMPLE = 5'd6, O_EMIT = 5'd7, O_NEXT_BYTE = 5'd8,
                         O_PARITY_OUT = 5'd9, O_PARITY_CHECK = 5'd10,
                         O_CRC_OUT = 5'd11, O_CRC_CHECK = 5'd12,
                         O_FRAME_BEGIN = 5'd13, O_FRAME_END = 5'd14,
                         O_SEL_ON = 5'd15, O_SEL_OFF = 5'd16,
                         O_CLK_RUN = 5'd17, O_CLK_STOP = 5'd18,
                         O_CLK_0 = 5'd19, O_CLK_1 = 5'd20, O_TIMER_SYNC = 5'd21,
                         O_SIGNAL = 5'd22, O_SET_ERR = 5'd23,
                         O_LOAD_COUNT = 5'd24, O_DEC_COUNT = 5'd25,
                         O_STREAM_OUT = 5'd26, O_STREAM_IN = 5'd27,
                         O_MATCH_ADDR = 5'd28, O_LOCK = 5'd29,
                         O_ENDS = 5'd30, O_END = 5'd31;

  // IMM ops
  localparam logic [3:0] I_LOAD_IMM = 4'd0, I_MATCH_IMM = 4'd1,
                         I_COUNT_IMM = 4'd2, I_CRC_SEL = 4'd3;

  // CNT special values (1-27 are literals)
  localparam logic [4:0] CNT_DATA_BITS = 5'd0, CNT_STOP = 5'd28,
                         CNT_COUNT = 5'd29, CNT_CRC_LEN = 5'd30;

  // Branch conditions: even = flag, odd = negation, 0 = ALWAYS
  localparam logic [4:0] C_ALWAYS = 5'd0,
                         C_S = 5'd1,      C_MATCH = 5'd3,  C_EMPTY = 5'd5,
                         C_ZERO = 5'd7,   C_MASTER = 5'd9, C_HOLD = 5'd11,
                         C_HELD = 5'd13,  C_RW = 5'd15,    C_B0 = 5'd17,
                         C_B1 = 5'd19,    C_ERR = 5'd21,   C_ENDF = 5'd23,
                         C_PEER = 5'd25,  C_SEL = 5'd27,   C_DIN = 5'd29;

  // ENDS set, in CNT: [4] SE0 [3] SEL_OFF [2] STOP [1:0] IDLE threshold
  localparam logic [4:0] ENDS_SE0 = 5'b10000, ENDS_SEL_OFF = 5'b01000,
                         ENDS_STOP = 5'b00100;
  localparam logic [1:0] ENDS_IDLE_OFF = 2'd0, ENDS_IDLE_2 = 2'd1,
                         ENDS_IDLE_8 = 2'd2, ENDS_IDLE_24 = 2'd3;

  // ------------------------------------------------------------ CRC residues
  // Register value after running over data plus its CRC field, reflected
  // form, all-ones init, no final XOR. Confirmed by the reference model in
  // test/gen_protocol_mem.py before use.
  localparam logic [4:0]  CRC5_RESIDUE  = 5'b01100;     // USB 2.0
  localparam logic [15:0] CRC16_RESIDUE = 16'h800D;     // USB 2.0
  localparam logic [31:0] CRC32_RESIDUE = 32'hDEBB20E3; // IEEE 802.3

endpackage
