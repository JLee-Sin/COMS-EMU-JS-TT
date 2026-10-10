// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// protocol_mem.sv - the protocol memory: SRAM macro, port arbiter and
// address map (arch.md: Protocol Memory).
//
// Module: protocol_mem
//   One 512 x 16-bit single-port SRAM (RM_IHPSG13_1P_512x16_c2_bm_bist,
//   behavioural array under `ifdef SIM, inferred block RAM on FPGA) holding
//   four protocol slots of 112 words (TX program at +0x00, RX program at
//   +0x38, 56 instructions each) at 0x70*n, and eight 8-word templates at
//   0x1C0. Ten requesters share the port through a round-robin arbiter:
//   requesters 0-7 are the sequencers (pinset p: 2p = TX, 2p+1 = RX),
//   8 is the Rewrite FSM, 9 is the Controller and the only writer. A
//   requester holds req and addr until its ack; read data is broadcast on
//   rdata and valid with the ack, two cycles after the grant.
//
//   The memory is not reset. The host loads the image after power-up.
//   Per-requester vectors are packed: bit r, or bits [9r+8:9r] for addr,
//   belong to requester r.

`default_nettype none

module protocol_mem (
    input  wire        clk,
    input  wire        rst_n,         // resets the arbiter only, not the array

    input  wire [9:0]  req,
    input  wire [89:0] addr,          // 10 x 9-bit word addresses
    input  wire        we,            // requester 9 only
    input  wire [15:0] wdata,         // requester 9 only
    output wire [15:0] rdata,         // broadcast
    output wire [9:0]  ack
);

endmodule
