// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// dump_mem.sv - the Memory Output Controller (arch.md: Memory Output
// Controller). One instance.
//
// Module: dump_mem
//   Streams one pinset's received bytes as fixed 8-byte memory slots on
//   MEM_DATA / MEM_CLK: up to 7 message bytes then a trailer {pinset, byte
//   count, error, truncated, continued}, MSB first, MEM_CLK at 10 MHz while
//   bits are sent and low otherwise. A 16-entry FIFO of {end, error,
//   truncated, byte} entries is fed by the one pinset whose mem_en is set;
//   a change of source flushes it. A full FIFO drops the entry and raises
//   ovf for that pinset. MEM_RESET stops the clock, drops the partial slot,
//   flushes the FIFO and restarts at a slot boundary.
//
//   Per-pinset vectors are packed: entry[11p+10:11p] belongs to pinset p.

`default_nettype none

module dump_mem (
    input  wire        clk,
    input  wire        rst_n,

    // From the pinsets
    input  wire [3:0]  push,
    input  wire [43:0] entry,         // {end, error, truncated, byte} per pinset
    input  wire [3:0]  mem_en,        // at most one bit set
    input  wire        mem_reset,     // from the Controller
    output wire [3:0]  ovf,           // entry dropped, sets rx_ovf

    // Pads and status
    output wire        mem_data,
    output wire        mem_clk,
    output wire        pending        // FIFO not empty or slot in progress
);

endmodule
