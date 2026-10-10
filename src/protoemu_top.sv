// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// protoemu_top.sv - top level of the protocol emulator, below the Tiny
// Tapeout wrapper.
//
// Module: protoemu_top
//   Instantiates and wires every block in the arch.md module hierarchy:
//   controller, rewrite_fsm, protocol_mem, pin_regs, pin_crossbar, four
//   pinset instances, dump_gui and dump_mem. It contains no logic of its
//   own. project.v maps the Tiny Tapeout pins onto the named ports here so
//   this module can be simulated or put on an FPGA without the TT interface.
//
//   Pin pool: P0-P7 are the bidirectional uio pins, P8-P11 the input-only
//   ui_in[7:4], P12-P15 the output-only uo_out[7:4] (arch.md: I/O).

`default_nettype none

module protoemu_top (
    input  wire        clk,         // 40 MHz system clock
    input  wire        rst_n,       // synchronous reset, active low

    // Host SPI (arch.md: Controller)
    input  wire        host_sck,    // ui_in[0]
    input  wire        host_mosi,   // ui_in[1]
    input  wire        host_cs_n,   // ui_in[2]
    output wire        host_miso,   // uo_out[0]

    // Dump outputs
    output wire        gui_tx,      // uo_out[1], 1 Mbaud UART records
    output wire        mem_data,    // uo_out[2]
    output wire        mem_clk,     // uo_out[3]

    // Pin pool pads
    input  wire [11:0] pool_in,     // P0-P7 from uio_in, P8-P11 from ui_in[7:4]
    output wire [15:0] pool_out,    // P0-P7 to uio_out, P12-P15 to uo_out[7:4]; [11:8] unused
    output wire [7:0]  pool_oe      // P0-P7 to uio_oe
);

endmodule
