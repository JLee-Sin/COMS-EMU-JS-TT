// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// dump_gui.sv - the GUI Output Controller (arch.md: GUI Output
// Controller). One instance.
//
// Module: dump_gui
//   Sends each complete record from a pinset's GUI buffer on GUI_TX as a
//   1 Mbaud 8N1 UART (BIT_DIV 40): protocol byte, blank, ROLE_MAP (2
//   bytes), blank, 1-8 message bytes, two blanks. A round-robin arbiter
//   picks the next ready record; rec_take releases the pinset's buffer once
//   its last byte is in the serializer. Reports dump_pending while a record
//   is ready or being sent.
//
//   Per-pinset vectors are packed: rec_hdr[24p+23:24p], rec_data[64p+63:64p],
//   rec_len[4p+3:4p], rec_flags[2p+1:2p] belong to pinset p.

`default_nettype none

module dump_gui (
    input  wire         clk,
    input  wire         rst_n,

    // Records from the pinsets
    input  wire [3:0]   rec_valid,
    input  wire [95:0]  rec_hdr,       // {PROTO, MASTER, pinset, error, truncated, ROLE_MAP}
    input  wire [255:0] rec_data,
    input  wire [15:0]  rec_len,       // 1-8 bytes
    input  wire [7:0]   rec_flags,     // {error, truncated}
    output wire [3:0]   rec_take,

    // Pad and status
    output wire         gui_tx,        // idle high
    output wire         dump_pending
);

endmodule
