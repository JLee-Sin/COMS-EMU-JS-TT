// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// host_spi.sv - host SPI receiver and MISO driver (arch.md: Controller,
// Receiver).
//
// Module: host_spi
//   Two-flop synchronizers on SCK, MOSI and CS_n; edge detection; an MSB-
//   first shift register with 3-bit bit counter; the 10-byte command buffer
//   with 4-bit byte counter and overflow flag; the MISO shift register,
//   loaded with the status byte on CS_n fall and with readback bytes on
//   request. Produces the cs_fall / cs_rise pulses on which cmd_decode
//   captures and commits. MISO drives 0 while CS_n is high.
//
//   Host timing limits are in arch.md: I/O, Host SPI timing (SCK <= 5 MHz).

`default_nettype none

module host_spi (
    input  wire        clk,
    input  wire        rst_n,

    // Pads
    input  wire        host_sck,
    input  wire        host_mosi,
    input  wire        host_cs_n,
    output wire        host_miso,

    // Frame events, one-cycle pulses in the clk domain
    output wire        cs_fall,         // frame start
    output wire        cs_rise,         // commit
    output wire        byte_done,       // a byte has landed in cmd_buf

    // Frame state, valid at cs_rise
    output wire [3:0]  byte_cnt,        // bytes received, 0-10
    output wire        bit_misaligned,  // bit counter not 0 (partial last byte)
    output wire        overflow,        // an 11th byte was seen
    output wire [79:0] cmd_buf,         // bytes 0-9, byte 0 in [79:72]

    // MISO data from cmd_decode
    input  wire [7:0]  status,          // loaded on cs_fall
    input  wire        miso_load,       // load miso_data as the next byte out
    input  wire [7:0]  miso_data
);

endmodule
