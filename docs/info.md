<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A protocol emulator with four independently programmable pinsets. Each pinset
can be switched at runtime to UART, SPI, I2C, or low-speed USB (10BASE-T is
experimental). Pinsets claim pins from a shared 16-pin pool (P0–P15): P0–P7
are `uio[7:0]` (bidirectional), P8–P11 are `ui_in[7:4]` (input only), and
P12–P15 are `uo_out[7:4]` (output only).

Protocols are programs, not fixed logic. Each pinset has two small sequencers
(transmit and receive) that run a protocol program from an on-chip SRAM and
drive shared primitives: shift registers, CRC, parity, bit stuffing, line
coding and bit timing. The SRAM holds four protocol slots and eight
configuration templates. The host loads the default image after power-up and
can rewrite any slot with WRITE_MEM, so a protocol the chip was not built for
can be added later if the primitives can express it.

A host configures the chip over SPI. SET_PROTO copies a template from the
protocol memory into a pinset's configuration registers, with optional baud
rate or address and pin-offset overrides. TRANSMIT sends up to 8 bytes on a
pinset. Commands execute when CS_n rises; malformed frames are ignored.

Received traffic is decoded and output two ways:

- **GUI output** (`uo_out[1]`): 1 Mbaud UART records in the form
  protocol, blank, pins used, blank, message, blank, blank.
- **Memory output** (`uo_out[2]` data, `uo_out[3]` clock): raw message bytes,
  MSB first, for capture into a memory bank.

## How to test

1. Set the project clock to 40 MHz.
2. Connect the RP2040 as SPI host: SCK to `ui_in[0]`, MOSI to `ui_in[1]`,
   CS_n to `ui_in[2]`, MISO to `uo_out[0]`. Keep SCK at 5 MHz or below.
3. Load the protocol image: 128 WRITE_MEM frames (`7x`, block, 8 data
   bytes) from `protocol_mem_default.hex`. The memory is volatile.
4. Loopback test: send `1C 03` (pinset 3 → UART, TX=P15, RX=P11) and
   jumper `uo_out[7]` to `ui_in[7]`.
5. Enable GUI dump: `2D`.
6. Transmit "Hi": `3C 02 48 69`.
7. Read `uo_out[1]` at 1 Mbaud. Expect `0C`, gap, `00 BF`, gap, `48 69`,
   double gap.
8. Send `00` and check status bit 7 is clear.

## External hardware

- Tiny Tapeout demo board (RP2040 as SPI host and GUI record parser)
- Pull-up resistors (4.7 kΩ) on any I2C pins
- USB transceiver for real USB devices; loopback between pinsets
  works without one
- Optional: logic analyzer on `uo_out[3:1]`
