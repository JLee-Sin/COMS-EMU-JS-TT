# SoC/IP Approach to Communication Protocol Emulation

Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery

## Table of Contents
1. [Introduction](#Introduction)
2. [OpCodes](#OpCodes)
3. [I/O](#I/O)
4. [IPs](#IPs)
   - [Controller](#Controller)
   - [Rewrite FSM](#Rewrite-FSM)
   - [Translation FSM](#Translation-FSM)
   - [Transmission FSM](#Transmission-FSM)
   - [Pinset Controller](#Pinset-Controller)
   - [Sequencer](#Sequencer)
   - [Register Bank](#Register-Bank)
   - [Protocol Memory](#Protocol-Memory)
   - [GUI Output Controller](#GUI-Output-Controller)
   - [Memory Output Controller](#Memory-Output-Controller)
5. [Integration](#Integration)
6. [Known Limitations](#Known-Limitations)

---

## Introduction

This chip emulates serial communication protocols on programmable pins. It has four independent pinsets. Each pinset can be switched at runtime to UART, SPI, I2C, low-speed USB, or Manchester-coded Ethernet framing, as either the controller or the target side where the protocol has one. A host configures the chip and sends messages over a dedicated SPI port. Received traffic is decoded on chip and sent out on a GUI output for live viewing and on a memory output for capture.

Protocols are not fixed in silicon. Each one is a pair of small programs, one for transmit and one for receive, held in an on-chip protocol memory together with the configuration templates. The programs run on a sequencer interpreter in every pinset and drive shared primitives (shift registers, CRC, parity, bit stuffing, line coding, bit timing). The host can rewrite any of the four protocol slots and any template over the SPI port, so a protocol the chip was not designed for can be added after fabrication as long as the primitives can express it.

**Target**

| Item | Value |
|---|---|
| Platform | Tiny Tapeout, `ttihp-verilog-template` branch `cmos5l` |
| Process | IHP 130 nm SG13CMOS5L, 5 metal layers |
| Tile size | 6 × 4 (about 0.7 mm², about 24K cell-equivalents) |
| System clock | 40 MHz (`CLOCK_PERIOD` = 25 ns) |
| Flow | LibreLane via the Tiny Tapeout GDS action |
| Macros | One IHP SRAM macro, `RM_IHPSG13_1P_512x16_c2_bm_bist` (8 Kbit, 236.8 × 191.3 µm, about 1.5 tiles), for the protocol memory |
| Simulation | cocotb on Icarus Verilog; gate-level sim after hardening |

**Design principles**

- One clock domain. Every external signal is synchronized into the 40 MHz domain and processed by edge detection. No signal from a pin is ever used as a clock.
- Configuration is atomic. A pinset never runs on a partly written configuration. Its VALID bit is cleared before any change and set as the final write.
- Pins are owned. Sixteen physical pins form a pool. A pinset claims pins through its role map, each pin has at most one owner, and only the owner can drive it.
- Commands commit on CS_n rise. A host command runs only after its whole frame has arrived. A truncated or malformed frame changes nothing.
- Reject rather than corrupt. A command that would break an invariant is refused whole and reported in the status byte.
- Shared primitives, per-protocol programs. Shift registers, line coders, CRC, parity and bit timing are configured by registers. Framing rules live only in the protocol programs. No module outside the protocol memory contains protocol-specific logic; the Controller, Rewrite FSM and primitives do not know what UART or I2C are.
- Programs are data. The protocol memory is volatile and host-loaded. The four default protocols are an image shipped with the design, written by the host after power-up with WRITE_MEM. A pinset reads its programs from the shared memory while it runs, so a slot in use by a live pinset cannot be rewritten.

**Terminology**

| Term | Meaning |
|---|---|
| Host | The external SPI controller that commands the chip. On the demo board, the RP2040. |
| Pinset | One of four emulation channels (ID 0–3). |
| Pool pin | One of 16 physical pins P0–P15 shared by all pinsets. |
| Slot | One of four entries in a pinset's role map. |
| Role | What a slot means for the current protocol (TX, SCLK, SDA, D+ ...). |
| Protocol slot | One of four regions of the protocol memory holding a TX program and an RX program. Selected by the PROTO field. |
| Program | A sequence of 16-bit instructions run by a sequencer. Each protocol slot holds one TX program and one RX program of up to 56 instructions each. |
| Sequencer | The interpreter in each pinset that runs a program. There are two per pinset, one for TX and one for RX. |
| Template | A protocol-memory entry holding the registers for one protocol configuration, including which slot it runs. |
| Image | The full default contents of the protocol memory: four program pairs and eight templates. ETH10 ships as an overlay that replaces one slot. |
| Record | One decoded message with its header, as sent on the GUI output. |
| Slot (memory) | One fixed 8-byte unit on the memory output. Called a memory slot where the two meanings could be confused. |
| Armed | A target-mode response loaded by TRANSMIT and waiting for the external controller. |
| MASTER | Pinset register bit selecting controller (1) or target (0) role on the emulated bus. Unrelated to the host. |

**Conventions**

- Bit ranges are `[msb:lsb]`. Bit 0 is least significant.
- Active-low signals end in `_n` or `_N`.
- Host SPI bytes are MSB first. Multi-byte fields are MSB first.
- "Cycle" means one 40 MHz system clock unless stated otherwise.

**Top-level structure**

```
                 Host SPI (ui_in[2:0], uo_out[0])
                             │
                 ┌───────────▼───────────┐
                 │       Controller      │  frame receive, decode, status
                 └──┬───────┬────────┬───┘
                    │       │        │ WRITE_MEM, READ_MEM
            ┌───────▼──┐    │   ┌────▼───────────────────┐
            │Rewrite   │    │   │ Protocol Memory (SRAM) │
            │FSM       ◄────┼───┤ 4 program slots        │
            └───┬──────┘    │   │ 8 templates            │
                │ writes    │   └────┬───────────────────┘
                │           │        │ instruction fetch ×8
      ┌─────────▼──────────▼┐       │
      │ Register Bank       │       │
      └─────────┬───────────┘       │
                │                   │
   ┌────────────▼───────────────────▼─────────────────┐
   │ Pinset Controller ×4                             │
   │   slot mux · event detector · primitives         │
   │   TX sequencer · RX sequencer · buffers          │
   └──────┬───────────────────────────────┬───────────┘
          │ pin pool P0–P15               │ decoded bytes
   ┌──────▼──────┐                 ┌──────▼─────────────────┐
   │ Pad logic   │                 │ GUI Output Controller  │──▶ uo_out[1]
   │ uio, ui, uo │                 │ Memory Output Ctrl     │──▶ uo_out[3:2]
   └─────────────┘                 └────────────────────────┘
```

---

## OpCodes

The host sends commands as SPI frames on the host port. A frame is everything between CS_n falling and CS_n rising: one header byte followed by zero to nine payload bytes.

```
CS_n  ‾‾\______________________________________________/‾‾
MOSI      [ header ][ payload 0 ] ... [ payload N-1 ]
MISO      [ status ][ 0x00, or READ_STATUS data      ]
                                                     ↑ commit
```

**Header byte**

| Bits | Field | Notes |
|---|---|---|
| 7:4 | OP | Op code |
| 3:2 | PS | Pinset ID 0–3. Ignored by NOP, READ_STATUS, MEM_RESET, WRITE_MEM, READ_MEM |
| 1:0 | SUB | Sub-op. Used by SET_PROTO, DUMP_CTRL and TRANSMIT, else 0 |

**Op code summary**

| OP | Name | Frame bytes | Executes in | Can be rejected |
|---|---|---|---|---|
| `0x0` | NOP | 1 | Controller | No |
| `0x1` | SET_PROTO | 2 or 4 | Rewrite FSM | Busy, pin conflict, incapable pin |
| `0x2` | DUMP_CTRL | 1 | Controller | No |
| `0x3` | TRANSMIT | 2 + N, N = 1–8 | Pinset Controller | Busy |
| `0x4` | READ_STATUS | 1 + 4 readback | Controller | No |
| `0x5` | RELEASE | 1 | Rewrite FSM | Busy |
| `0x6` | MEM_RESET | 1 | Memory Output Controller | No |
| `0x7` | WRITE_MEM | 10 | Protocol Memory | Busy |
| `0x8` | READ_MEM | 2 + 8 readback | Protocol Memory | No |
| `0x9`–`0xF` | Reserved | — | — | Always rejected, bad frame |

### NOP

Frame `0x00`. Returns the status byte and clears the reported error bits. No other effect.

### SET_PROTO

Loads a template into pinset PS.

| Byte | Content |
|---|---|
| 0 | `0x1`, PS, SUB: `[1]` 0, `[0]` override kind: 0 BIT_DIV, 1 ADDR |
| 1 | `[7:5]` template index, `[4]` override present, `[3:0]` pin offset |
| 2–3 | Override value V, MSB first. Present only when byte 1 bit 4 is set |

Template indices in the default image: 0 UART, 1 SPI controller, 2 SPI target, 3 I2C controller, 4 I2C target, 5 USB_LS, 6 ETH10, 7 RAW. A template names the protocol slot it runs in its PROTO field, so after the host rewrites the protocol memory the indices mean whatever the host loaded.

The pin offset is added to every enabled slot of the template's ROLE_MAP. It moves the whole protocol as a block.

The override replaces one field of the template's pinset register. The host chooses which with SUB bit 0; the Rewrite FSM does not know what the template is.

| SUB[0] | V |
|---|---|
| 0 | BIT_DIV `[15:0]`, system clocks per bit (per half-bit when LINE_CODE is Manchester). Meaningless for a template with CLKED = 1, where the external clock sets the rate; the value is stored and ignored |
| 1 | ADDR `[6:0]`, the 7-bit own address. `[15:7]` must be 0 |

Validation happens before any change:

1. Busy if pinset PS is actively transmitting (`tx_lock`) or the Rewrite FSM is active.
2. Bad frame if the template's PROTO field is 4, 5 or 6 (no such slot).
3. For each enabled slot, target pin = template slot + offset. Pin conflict if the target is above P15 or owned by another pinset.
4. Incapable pin if the role needs a capability the target pin does not have (see I/O, pool capabilities).

On success the Rewrite FSM runs the sequence in its section and the pinset goes live in about 200–300 cycles, most of it waiting for template reads from the protocol memory. On failure nothing changes.

Examples: `1C 03` sets pinset 3 to UART with offset 3 (TX P15, RX P11). `1C 13 10 47` does the same at 9600 baud (BIT_DIV 4167). `15 90 00 50` sets pinset 1 to I2C target at address 0x50.

### DUMP_CTRL

One byte. SUB selects the action for pinset PS.

| SUB | Action | Timing |
|---|---|---|
| `00` | GUI dump off | A record already being sent finishes first |
| `01` | GUI dump on | Forwarding starts at the next message boundary |
| `10` | Memory dump off | Takes effect after the current memory slot |
| `11` | Memory dump on | Clears memory enable on all other pinsets. The memory FIFO is flushed if the source changes |

Enables may be set while the pinset is invalid. They apply once it goes live. RELEASE clears both enables.

### TRANSMIT

Queues a message on pinset PS.

| Byte | Content |
|---|---|
| 0 | `0x3`, PS, SUB: `[1]` PERSIST, `[0]` HOLD |
| 1 | Length N, 1–8 |
| 2 … N+1 | Payload |

Rejected as bad frame if N is 0, above 8, or does not match the byte count. Rejected busy if pinset PS is invalid or `tx_lock` is set (see below).

**Payload by protocol**

| Protocol | Byte 0 | Rest |
|---|---|---|
| UART | Data | Data |
| SPI controller | Data | Data. CS is held low for the whole message |
| SPI target | Data | Data. Shifted out on MISO when the external controller asserts CS |
| I2C controller, write (byte 0 bit 0 = 0) | 7-bit address in `[7:1]`, 0 in `[0]` | Data bytes written to the target |
| I2C controller, read (byte 0 bit 0 = 1) | 7-bit address in `[7:1]`, 1 in `[0]` | Byte 1 = number of bytes to read, 1–255. N should be 2 |
| I2C target | Data | Data. Sent when the external controller reads from the pinset's address |
| USB_LS | PID byte as sent on the wire: PID in `[3:0]`, its complement in `[7:4]` | Packet payload. SYNC, CRC and EOP are added |
| ETH10 | Data | Data. Preamble, SFD and CRC32 are added |
| RAW | Data | Data. Sent on slot 0 with no framing |

The Controller checks only N against the byte count. What the payload means is defined by the protocol program, so the table above describes the default image. The default I2C program treats a read with count 0 as an error: it sends STOP and flags the message. Bytes read from the target go to the dump outputs as one message, the same as any receive.

**HOLD (SUB bit 0), I2C controller only.** The sequencer omits the STOP after the message and holds SCL low. The next TRANSMIT on the pinset begins with a repeated START instead of a START. This is how a register read is done: a HOLD write of the register address, then a read. Transmit-busy clears after the held message as usual. RELEASE or SET_PROTO on a pinset holding the bus releases the lines without a STOP. HOLD is ignored on other protocols.

**PERSIST (SUB bit 1), target modes only.** The response re-arms from byte 0 after every transaction until it is replaced by another TRANSMIT, or the pinset is released or reconfigured. Without PERSIST the response is consumed by the first transaction. PERSIST is ignored in controller modes.

**Controller modes.** The message is sent at once. Transmit-busy is set from the load until the last bit leaves the pins, and `tx_lock` equals transmit-busy.

**Target modes.** TRANSMIT arms a response. Transmit-busy means armed or active. `tx_lock` is set only while the response is active: from CS assertion to CS deassertion on an SPI target, or from address match to STOP on an I2C target. While a response is merely armed, a new TRANSMIT replaces it. A one-shot response that is only partly consumed (CS deasserted early, or an early NACK) is discarded whole. A persistent response restarts from byte 0 at the next transaction. If the external controller takes more bytes than were loaded, or reads when nothing is armed, an SPI target shifts 0 and an I2C target sends 0xFF. Neither sets an error.

Examples: `3C 02 48 69` sends "Hi" on pinset 3. `35 02 A0 10` then `34 02 A1 04` writes register 0x10 to I2C device 0x50 on pinset 1 and reads 4 bytes with a repeated START. `3A 02 DE AD` arms a persistent 2-byte SPI target response on pinset 2.

### READ_STATUS

The host sends the header and then clocks four more bytes. The values are captured when CS_n falls.

| Readback byte | Content |
|---|---|
| 1 | `[7:4]` VALID per pinset, `[3:0]` transmit-busy per pinset |
| 2 | `[7:4]` RX overflow per pinset (cleared on read), `[3]` Rewrite FSM busy, `[2:0]` reserved |
| 3 | Owned-pin mask P15–P8 |
| 4 | Owned-pin mask P7–P0 |

While Rewrite FSM busy is set, VALID and the ownership masks may be mid-update.

### RELEASE

One byte. Shuts pinset PS down. Rejected busy if `tx_lock` is set or the Rewrite FSM is active.

Actions: clear VALID, abort any receive in progress, flush the TX and GUI buffers, drop any armed response, clear EN and OWNER on every pin the pinset owned, clear both dump enables.

### MEM_RESET

One byte. Stops MEM_CLK, drops the partial memory slot, flushes the memory FIFO, and restarts at a slot boundary. The host resets its capture logic at the same time.

### WRITE_MEM

Writes one 4-word block of the protocol memory.

| Byte | Content |
|---|---|
| 0 | `0x7`, `0000` |
| 1 | Block address B, 0–127. Word address = 4B. Bit 7 must be 0 |
| 2–9 | Words 4B to 4B+3, each MSB first |

The frame must be exactly 10 bytes, and a block address above 127 is a bad frame. Blocks are the unit of writing because every structure in the memory map is block-aligned: a program is 14 blocks, a protocol slot 28, a template 2.

Rejected busy if the Rewrite FSM is active, or if the block lies in a protocol slot that any valid pinset is running (its PROTO equals the slot index). Templates can be written while pinsets run, because a template is only read during SET_PROTO. Reserved addresses can be written and have no effect.

The four words are written through the memory port after CS_n rises; the write completes within about 50 cycles, long before the next frame can finish.

Loading the full default image takes 128 frames (112 program blocks and 16 template blocks), about 2 ms at 5 MHz SCK.

### READ_MEM

Reads one block back. The host sends the header and block address, then clocks eight more bytes and receives words 4B to 4B+3, MSB first.

| Byte | Content |
|---|---|
| 0 | `0x8`, `0000` |
| 1 | Block address B, 0–127 |
| 2–9 | Readback, MOSI ignored |

The block is fetched through the memory port when byte 1 completes, which can take up to about 50 cycles. The host must idle SCK for at least 1.5 µs between the end of byte 1 and the start of byte 2; see the host SPI timing table.

### Status byte

Shifted out on MISO, MSB first, while the header byte shifts in. It describes the previous command.

| Bit | Field |
|---|---|
| 7 | Last command failed |
| 6:5 | Error code |
| 4 | Dump data pending: a GUI record is ready or being sent, or the memory FIFO is not empty |
| 3:0 | Transmit-busy, pinset 3 down to pinset 0 |

| Error code | Name | Raised by |
|---|---|---|
| `00` | Bad frame | Wrong byte count, partial last byte, buffer overflow, reserved op, TRANSMIT length 0 or above 8, SET_PROTO of a template whose PROTO is 4–6, WRITE_MEM or READ_MEM block above 127 |
| `01` | Pin conflict | Target pin owned by another pinset, or offset pushes a slot past P15 |
| `10` | Incapable pin | Role needs a capability its pin lacks |
| `11` | Busy | Rewrite in progress, `tx_lock` set, TRANSMIT to an invalid pinset, WRITE_MEM to a slot a valid pinset is running |

Bits 7:5 clear after they have been shifted out once. The status byte holds the result of the most recent command only. A host confirms a command by following it with a NOP or by reading the status returned with its next command. A host that sends frames faster than it checks status can miss a failure; READ_STATUS shows the resulting state.

### Command latency

At 5 MHz SCK each byte takes 1.6 µs (64 cycles).

| Command | Bytes | Transfer | Execute | Total |
|---|---|---|---|---|
| NOP, DUMP_CTRL, MEM_RESET | 1 | 1.6 µs | 1 cycle | ~1.7 µs |
| RELEASE | 1 | 1.6 µs | 10–40 cycles | ~1.7–2.6 µs |
| SET_PROTO | 2 | 3.2 µs | 200–300 cycles | ~8–11 µs |
| SET_PROTO with override | 4 | 6.4 µs | 200–300 cycles | ~11.5–14 µs |
| TRANSMIT, 8 bytes | 10 | 16 µs | 1 cycle, then line time | ~16 µs to start |
| WRITE_MEM | 10 | 16 µs | ≤ 50 cycles | ~17 µs |
| READ_MEM | 2 + 8 | 16 µs + 1.5 µs pause | ≤ 50 cycles | ~18 µs |

Back-to-back TRANSMIT frames deliver about 500 KB/s. That covers UART, SPI at 1 MHz and USB_LS, but not sustained 10BASE-T.

---

## I/O

### Tiny Tapeout pin map

| TT pin | Name | Direction | Function |
|---|---|---|---|
| `ui_in[0]` | HOST_SCK | In | Host SPI clock |
| `ui_in[1]` | HOST_MOSI | In | Host SPI data in |
| `ui_in[2]` | HOST_CS_N | In | Host SPI select, active low |
| `ui_in[3]` | — | In | Spare. Reserved for a second MOSI line if the host port needs more bandwidth |
| `ui_in[7:4]` | P8–P11 | In | Pool pins, input only |
| `uo_out[0]` | HOST_MISO | Out | Host SPI data out |
| `uo_out[1]` | GUI_TX | Out | GUI output, UART 1 Mbaud |
| `uo_out[2]` | MEM_DATA | Out | Memory output data |
| `uo_out[3]` | MEM_CLK | Out | Memory output clock |
| `uo_out[7:4]` | P12–P15 | Out | Pool pins, output only |
| `uio[7:0]` | P0–P7 | Bidir | Pool pins |
| `clk` | — | In | 40 MHz system clock |
| `rst_n` | — | In | Synchronous reset, active low |
| `ena` | — | In | Unused |

`info.yaml` pinout section:

```yaml
pinout:
  ui[0]: "HOST_SCK"
  ui[1]: "HOST_MOSI"
  ui[2]: "HOST_CS_N"
  ui[3]: ""
  ui[4]: "P8 (pool in)"
  ui[5]: "P9 (pool in)"
  ui[6]: "P10 (pool in)"
  ui[7]: "P11 (pool in)"
  uo[0]: "HOST_MISO"
  uo[1]: "GUI_TX"
  uo[2]: "MEM_DATA"
  uo[3]: "MEM_CLK"
  uo[4]: "P12 (pool out)"
  uo[5]: "P13 (pool out)"
  uo[6]: "P14 (pool out)"
  uo[7]: "P15 (pool out)"
  uio[0]: "P0 (pool bidir)"
  uio[1]: "P1 (pool bidir)"
  uio[2]: "P2 (pool bidir)"
  uio[3]: "P3 (pool bidir)"
  uio[4]: "P4 (pool bidir)"
  uio[5]: "P5 (pool bidir)"
  uio[6]: "P6 (pool bidir)"
  uio[7]: "P7 (pool bidir)"
```

### Pool capabilities

| Pool pins | TT pins | Allowed DIR | Allowed DRIVE | State when unowned or owner invalid |
|---|---|---|---|---|
| P0–P7 | `uio[7:0]` | in, out, bidir | push-pull, open-drain, differential, hi-Z | `uio_oe = 0` |
| P8–P11 | `ui_in[7:4]` | in | — | Input ignored |
| P12–P15 | `uo_out[7:4]` | out | push-pull, differential | Drives 0 |

Consequences:

- I2C and USB_LS need bidirectional pins, so both roles must land on P0–P7.
- UART, SPI and Ethernet fit on P8–P15 and default there to keep the bidirectional pins free.
- A differential pair should use adjacent pins of the same type.
- P12–P15 cannot tri-state. Their safe state while owned is IDLE_LVL; while unowned it is 0.

### Pad mapping of per-pin register fields

| Field | Implementation |
|---|---|
| DIR | Sets `uio_oe` for P0–P7. Fixed for other pins; the Rewrite FSM rejects a mismatch |
| DRIVE push-pull | `uio_out = data`, `uio_oe = 1` |
| DRIVE open-drain | `uio_out = 0`, `uio_oe = ~data` |
| DRIVE differential | Two pins driven complementary by the Transmission FSM. Levels are logic-level only |
| DRIVE hi-Z | `uio_oe = 0` |
| IDLE_LVL | Level driven when the pinset is idle or VALID is 0 |
| INVERT | XOR at the pad, both directions |
| FILTER | Glitch filter in logic, after a 2-flop synchronizer. Depth 0–15 cycles |

### Electrical notes

- Logic levels only. Real USB needs its own differential levels and pull-up signalling; real 10BASE-T needs magnetics and about ±2.5 V differential drive. Use external transceivers or loop back between two pinsets.
- There are no programmable pulls; Tiny Tapeout pads have none. I2C lines need external pull-ups (4.7 kΩ is typical). Which templates need pulls is recorded as comments in the image generator, not in silicon.
- Every pool input passes a 2-flop synchronizer before any logic. Add FILTER cycles on top. Keep FILTER well below a bit period: at most 3 for USB_LS, 0 for Ethernet.

### Host SPI timing

| Parameter | Limit | Reason |
|---|---|---|
| SCK frequency | ≤ 5 MHz | MISO is updated 2–3 cycles after the detected falling edge and must be valid at the next rising edge |
| SCK high and low time | ≥ 100 ns | At least two system clocks per phase so no edge is missed |
| CS_n fall to first SCK rise | ≥ 100 ns | Status bit 7 is loaded on CS_n fall and must reach MISO first |
| Last SCK fall to CS_n rise | ≥ 100 ns | The last bit must be captured before commit |
| CS_n high between frames | ≥ 100 ns | Both CS_n edges must be detected |
| READ_MEM: last SCK of byte 1 to first SCK of byte 2 | ≥ 1.5 µs | The block is fetched through the shared memory port, up to about 50 cycles |

MISO drives 0 whenever CS_n is high.

### GUI and memory outputs

| Signal | Format |
|---|---|
| GUI_TX | UART, 1 Mbaud, 8 data bits, no parity, 1 stop bit. Idle high |
| MEM_DATA | One bit per MEM_CLK period, MSB first. Changes on the MEM_CLK falling edge |
| MEM_CLK | 10 MHz (system clock ÷ 4) while bits are being sent, otherwise held low |

### Clock and reset

- `clk` is 40 MHz from the demo board. All flops use its rising edge.
- `rst_n` is treated as a synchronous reset. Hold it low for at least 10 cycles. It clears every VALID, EN and OWNER bit, all buffers, dump enables, the status register and the host SPI receiver. After reset: MISO 0, GUI_TX 1, MEM_DATA 0, MEM_CLK 0, P0–P7 hi-Z, P12–P15 low.
- The protocol memory is not reset. Its contents are undefined after power-up and survive `rst_n`. The host loads the image before the first SET_PROTO; until then only RAW (built in, no memory) can be used.
- `ena` is ignored.

---

## IPs

### Controller

Files: `controller.sv`, `host_spi.sv`, `cmd_decode.sv`.

`controller.sv` is the Controller's top file. It contains no logic of its own: it instantiates `host_spi` (receiver and MISO) and `cmd_decode` (decoder and status register), wires them together, and exposes the interfaces listed below to `protoemu_top`.

The Controller receives frames on the host port, validates them on CS_n rise, dispatches each accepted command to its target, and keeps the status register.

**Receiver**

1. Synchronizers. HOST_SCK, HOST_MOSI and HOST_CS_N each pass through two flops. SCK and CS_n must be synchronized because they drive control logic. MOSI is synchronized to keep it delay-matched with SCK and to contain metastability from a misbehaving host.
2. Edge detection. Each synchronized signal is compared with its value one cycle earlier:

```verilog
wire sck_rise = sck_sync & ~sck_prev;   // capture a MOSI bit
wire sck_fall = ~sck_sync & sck_prev;   // drive the next MISO bit
wire cs_fall  = ~cs_sync  & cs_prev;    // frame start
wire cs_rise  =  cs_sync  & ~cs_prev;   // commit
```

3. Shift register. On each `sck_rise` the MOSI bit shifts into an 8-bit register and a 3-bit bit counter advances. When the counter wraps, the byte is written to the command buffer and a 4-bit byte counter advances.
4. Command buffer. 10 bytes, the longest legal frame. `cs_fall` clears both counters. An 11th byte sets an overflow flag.
5. MISO shift register. Loaded with the status byte on `cs_fall`; bit 7 is driven at once. Each `sck_fall` shifts out the next bit. After the header the register holds 0, except during READ_STATUS, when it is reloaded with each readback byte, and READ_MEM, when it is reloaded from the block fetched after byte 1.

**READ_MEM, during the frame.** When byte 1 completes and the header is `0x8`, the Controller requests the four words of block B from the memory port and holds them in a 64-bit readback register. The MISO register is loaded from it byte by byte from byte 2 on. The request is made before commit because the data must be on MISO before CS_n rises; nothing else happens until the frame is validated.

**Decoder, on `cs_rise`**

1. Reject as bad frame if the bit counter is not 0, the overflow flag is set, OP is reserved, or the byte count does not match OP. For TRANSMIT, also check N against the byte count. The payload is not interpreted.
2. Otherwise dispatch:

| OP | Action |
|---|---|
| NOP | Clear status bits 7:5 |
| SET_PROTO | Assert `rw_req` with `rw_op = SET`, PS, template index, offset, override flag and V |
| DUMP_CTRL | Set or clear the enable flop for PS. Memory on also clears the other three memory enables |
| TRANSMIT | If `valid[PS]` and not `tx_lock[PS]`: copy payload and N to pinset PS in one cycle with the HOLD and PERSIST flags, assert `tx_load[PS]`. Else error busy |
| READ_STATUS | Nothing; the snapshot was taken on `cs_fall` |
| RELEASE | Assert `rw_req` with `rw_op = RELEASE`, PS |
| MEM_RESET | Pulse `mem_reset` |
| WRITE_MEM | Busy if `rw_busy`, or if block B is in slot S = B / 28 (B < 112) and `valid[X] && proto[X] == S` for any X. Else issue four writes to the memory port from the command buffer |
| READ_MEM | Nothing; the block was fetched during the frame |

3. Latch the result into the status register. For Rewrite FSM commands the result arrives on `rw_done` / `rw_err` some cycles later, long before the next frame can complete. WRITE_MEM reports success when accepted; the writes themselves cannot fail.

**Interfaces**

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `rw_req`, `rw_op`, `rw_ps`, `rw_tmpl`, `rw_ovr`, `rw_val`, `rw_offset` | out | 1, 1, 2, 3, 1, 16, 4 | Request to the Rewrite FSM |
| `rw_busy`, `rw_done`, `rw_err` | in | 1, 1, 2 | Rewrite FSM status and result |
| `tx_load[3:0]`, `tx_len[3:0]`, `tx_data[63:0]`, `tx_hold`, `tx_persist` | out | — | TRANSMIT payload and flags to the pinsets |
| `gui_en[3:0]`, `mem_en[3:0]` | out | — | Dump enables |
| `mem_reset` | out | 1 | To the Memory Output Controller |
| `pm_req`, `pm_we`, `pm_addr[8:0]`, `pm_wdata[15:0]`, `pm_rdata[15:0]`, `pm_ack` | out / in | — | Protocol memory port, one word per request |
| `valid[3:0]`, `tx_busy[3:0]`, `tx_lock[3:0]`, `rx_ovf[3:0]`, `proto[3:0][2:0]`, `master[3:0]`, `dump_pending`, `owned[15:0]` | in | — | Status inputs |

**Timing.** The TRANSMIT copy takes one cycle. A WRITE_MEM issues four port requests in sequence; the command buffer is held until the last is acknowledged, at most about 50 cycles. The next frame cannot complete its first byte for about 64 cycles, so no double buffering of the command buffer is needed.

### Rewrite FSM

File: `rewrite_fsm.sv`. One instance, shared by all pinsets.

The Rewrite FSM is the only writer of the register bank. It streams a template from the protocol memory into a pinset's registers, applies the override, and enforces pin ownership and capability rules. It reads the template one word at a time through the shared memory port; each read takes up to about 12 cycles, which dominates the sequence.

**States**

```
IDLE → CHECK → INVALIDATE → FLUSH → SETTLE → RELEASE_PINS → WRITE_PINS → WRITE_CHANNEL → DONE
                   │
                   └── reject → DONE (rw_err set, nothing written)
```

**Sequence for SET_PROTO**

1. CHECK. Reject busy if `tx_lock[PS]`. Read template words 7, 4 and 0–3 through the port. Reject as bad frame if word 7's PROTO field (bits `[14:12]`) is 4, 5 or 6. For each slot whose per-pin word has EN set, take the slot's ROLE_MAP nibble from word 4 and add the offset. Reject with pin conflict if the sum exceeds 15 or if `pin_en[target] && owner[target] != PS`. Two slots of the same template may name the same pin. Reject with incapable pin if the slot's DIR or DRIVE is not allowed on the target pin. The check takes six port reads plus four cycles.
2. INVALIDATE. Clear `valid[PS]`. The pinset's FSMs return to idle; its pads go to the safe state.
3. FLUSH. Assert `rx_abort[PS]` and `buf_flush[PS]` for one cycle. A partial received message is marked truncated and dropped. An armed response is dropped.
4. SETTLE. Wait 2 cycles so registered pad outputs show safe values before any pin register changes.
5. RELEASE_PINS. For each pin with `pin_en && owner == PS` that is not a target of the new map, clear EN and OWNER. One pin per cycle, 16 cycles maximum.
6. WRITE_PINS. Read template words 0–3 again through the port. For each enabled slot, write the word as it arrives into per-pin register `target` with OWNER set to PS and EN set. CHECK keeps only each slot's enable bit and target pin (20 bits), not the words, so there is no 64-bit staging register; the four extra reads cost about 50 cycles.
7. WRITE_CHANNEL. Read template words 4–7 through the port and write each into pinset register PS as it arrives, with patches:
   - Word 4: add the offset to every ROLE_MAP nibble whose slot is enabled. Disabled slots keep their nibble; a program may still read such a slot (I2C maps slot 1 to the SDA pin this way).
   - Word 5: if `rw_ovr` and `rw_kind` = ADDR, set bits `[7:1]` to V`[6:0]`.
   - Words 6–7: if `rw_ovr` and `rw_kind` = BIT_DIV, replace BIT_DIV (register bits 56:41: word 6 bits `[15:9]` hold BIT_DIV`[6:0]`, word 7 bits `[8:0]` hold BIT_DIV`[15:7]`).
   - Word 7: force bit 15 (VALID) to 1. This is the last write.
8. DONE. Pulse `rw_done` with `rw_err`.

The FSM never inspects a template beyond PROTO, EN, DIR, DRIVE and ROLE_MAP. Which override applies is the host's choice, so a new protocol needs no change here.

**Sequence for RELEASE**

Step 1 (busy check only), then steps 2–4, then clear EN and OWNER on every pin with `owner == PS`, then DONE. The Controller clears the dump enables.

**Interfaces**

| Signal | Dir | Meaning |
|---|---|---|
| Request bus from Controller, plus `rw_kind` | in | As listed under Controller |
| `pm_req`, `pm_addr[8:0]`, `pm_rdata[15:0]`, `pm_ack` | out, in | Read port to the protocol memory. Address = `0x1C0 + 8 × template + word` |
| `pin_we`, `pin_addr[3:0]`, `pin_wdata[15:0]` | out | Per-pin register write port |
| `ps_we`, `ps_sel[1:0]`, `ps_word[1:0]`, `ps_wdata[15:0]` | out | Pinset register write port, 16 bits at a time |
| `valid_clr[3:0]` | out | Clears VALID ahead of writes |
| `rx_abort[3:0]`, `buf_flush[3:0]` | out | To the pinsets |
| `pin_en[15:0]`, `owner[15:0][1:0]`, `tx_lock[3:0]` | in | For checks |

**Properties the FSM must satisfy**

- `pinset_cfg[X][62:0]` changes only while `valid[X]` is 0.
- A per-pin register changes only if the pin is unowned or its owner is invalid.
- No pin has two owners. Every owned pin appears in its owner's ROLE_MAP.
- A rejected request changes no register and no buffer.

### Translation FSM

File: `rx_fsm.sv`. One instance per pinset.

The Translation FSM decodes traffic on the pinset's pins into bytes and events. It is a seven-stage pipeline. Each stage passes a one-cycle valid strobe and data to the next. There is no backpressure: the wire cannot be paused, so each stage handles one bit per cycle at most. Every stage reads the pinset register live and is held idle while VALID is 0.

```
pool pins → [1] slot mux → [2] event detector → [3] bit timing → [4] line decode
          → [5] check + shift → [6] RX sequencer → [7] output staging
```

Stages 1–5 and 7 are shared primitives configured by registers. Stage 6 is a sequencer running the RX program of the pinset's protocol slot; it is the only place framing rules exist, and they arrive as data.

**1. Slot mux**

Selects the four slot signals `s0`–`s3` from the 16 pool inputs using the ROLE_MAP nibbles (four 16:1 muxes). The outputs are registered; this is the likely critical path. For a slot whose pin is output-only, or whose DIR is out, the slot input is the pinset's own driven level, so a controller sees its own clock and select.

Slot roles are a fixed convention shared by every program:

| Slot | Role | Used by |
|---|---|---|
| 0 | DOUT: the line the TX sequencer drives. With DRIVE = differential, slot 1 is driven as its complement | TX |
| 1 | DIN: the line the RX sequencer samples by default. Also the second line of a differential pair (SE0 detection) | RX, TX SAMPLE |
| 2 | CLK: driven by the TX sequencer in a clocked controller, an event source in a clocked target | Both |
| 3 | SEL: chip select, active low at the slot (use INVERT for active-high) | Both |

RX_SLOT in the pinset register moves the sampled line to any slot, which is how Ethernet receives on its own pair (slot 2) while slots 0–1 transmit. Two slots may name the same pin: the default I2C template maps slots 0 and 1 both to SDA.

**2. Event detector**

Stores each slot's previous value and produces one-cycle pulses: DIN rise, fall and edge; CLK rise and fall; SEL on and off; START (DIN falls while CLK high) and STOP (DIN rises while CLK high); SE0 (slots 0 and 1 both low). A slot whose per-pin word is `0x0000` reads as 1 and produces no events, so an unmapped select or clock cannot disturb a program. Both sequencers wait on these pulses, so there is one detector per pinset.

**3. Bit timing**

Produces a sample tick for the RX sequencer and a drive tick for the TX sequencer. The mode comes from two register fields, not from the protocol:

- CLKED = 1 (clocked target): the ticks are the CLK slot's edges. CPOL and CPHA choose which edge samples; the other edge drives. Ticks are gated by SEL when slot 3 is mapped. The tick is suppressed in the cycle of a START or STOP. With CPHA = 0 a drive tick is also produced when SEL asserts, so the first bit is on the line before the first clock edge.
- CLKED = 0, LINE_CODE NRZ or NRZI (internal timing): a 16-bit phase counter reloads to BIT_DIV−1 and produces one drive tick and one sample tick (half a bit later) per period. TIMER_SYNC from the RX program reloads it to BIT_DIV/2 so the next sample tick lands mid-bit; with LINE_CODE = NRZI every DIN edge does the same automatically, which is what USB_LS needs (bit stuffing guarantees an edge at least every 7 bits; worst-case drift about 8% of a bit with BIT_DIV 27). In a clocked controller CLK_RUN mirrors the counter onto the CLK slot.
- CLKED = 0, LINE_CODE Manchester: an interval counter measures cycles between DIN edges. Intervals shorter than 1.5 × BIT_DIV are half-bit, longer are full-bit; a flag tracks whether the next edge is mid-bit. Each mid-bit edge produces a sample tick with the bit: rising is 1, falling is 0. The drive tick runs every BIT_DIV cycles (one half-bit).

The same counter measures idle time in bit times since the last DIN edge. The IDLE wait and the ENDS frame-end set read it; the thresholds are in the program, not here.

**4. Line decode**

- NRZ: the sampled level is the bit.
- NRZI (USB): no change from the previous J/K state is 1, a change is 0.
- Manchester: the bit from stage 3.

The destuffer (enabled by BIT_STUFF) counts consecutive 1s. After six, the next bit is dropped; if that bit is a 1, a stuff error is flagged.

**5. Check and shift**

- CRC: one right-shifting register with a selectable polynomial, reflected form, covers CRC5, CRC16 and CRC32. The polynomial comes from the CRC field or from the program's CRC_SEL, which also resets the register to all ones. It runs over every bit passed through SHIFT_IN while enabled, including the CRC field. CRC_CHECK compares the register with the width's fixed residue, so a program never needs to locate the CRC field. Residue constants come from the USB 2.0 and IEEE 802.3 specifications.
- Parity: one flop XORs each data bit; PARITY_CHECK samples the parity slot and compares against PARITY.
- Deserializer: each bit is written to position `cnt` (LSB first) or `DATA_BITS − cnt` (MSB first) of a 16-bit word. The word clears on EMIT. STREAM_IN emits automatically every DATA_BITS bits.

**6. RX sequencer**

A sequencer (see the Sequencer section) running the RX program at word `0x38` of the pinset's protocol slot. It starts at instruction 0 when VALID rises and runs until VALID falls. It decides when a frame begins and ends, which bits are data, and what to check. Everything it can do is listed in the instruction set; the default RX programs are in the Protocol Memory section.

Framing, parity, stuff and CRC errors set the error flag on the current message through SET_ERR, PARITY_CHECK and CRC_CHECK. If VALID drops mid-frame, the sequencer stops and the open message is marked truncated.

**7. Output staging**

- FRAME_BEGIN: snapshot PROTO, MASTER and ROLE_MAP for the record header and open a message. Idempotent while a message is open.
- EMIT: write the byte to the GUI buffer if `gui_en` and push `{end, error, truncated, byte}` to the memory FIFO if `mem_en`.
- FRAME_END, or when 8 bytes have accumulated: mark the GUI record ready. A longer message continues in a new record with the same header.
- If the GUI buffer is still full from the previous record: drop the byte and set `rx_ovf`.

**Area estimate (cell-equivalents)**

| Block | Per pinset |
|---|---|
| Event detector | ~150 |
| Bit timing | ~300 |
| Line decode + destuffer | ~100 |
| CRC + parity | ~190 |
| Deserializer | ~200 |
| RX sequencer | ~400 |
| Output staging | ~100 |
| Total | ~1.45K |

**Latency.** About 5–6 cycles from a pin edge to a decoded bit. Within a STREAM_IN no instruction fetch is needed per bit. A taken branch costs one fetch through the shared port, up to about 12 cycles; the default programs place branches only at byte or frame boundaries. The tightest target-mode deadline is SPI target MISO at 1 MHz (500 ns half period, about 3× margin). SPI target tops out near 5 MHz SCLK. Manchester framing at BIT_DIV 2 (10 Mbit/s) leaves only 4 cycles per bit, less than one fetch, so the default ETH10 program is specified for BIT_DIV ≥ 6 (about 3.3 Mbit/s).

### Transmission FSM

File: `tx_fsm.sv`. One instance per pinset.

The Transmission FSM encodes a message from the TX buffer and drives it onto the pinset's pins. Its sequencer starts when a message is loaded. In a controller the program sends at once; in a target the program's first instructions wait for the external controller, which is what "armed" means.

```
TX buffer → [1] TX sequencer → [2] serializer → [3] parity / CRC → [4] bit stuffer
          → [5] line encoder → [6] bit timing → [7] pin driver
```

**1. TX sequencer.** A sequencer running the TX program at word `0x00` of the pinset's protocol slot. `tx_load` starts it at instruction 0. END stops it; with PERSIST in a target (MASTER = 0) END instead rewinds the buffer and restarts at 0. Invalidation or `buf_flush` stops it and returns the pins to idle. What the program does before, per and after each byte is up to the program; the default framing for each protocol is in the Protocol Memory section.

**Signals between the two sequencers**

The I2C-specific handshake of the hard-wired design is replaced by three generic signals. Any protocol that needs the two sides to coordinate uses them.

| Signal | Set by | Meaning |
|---|---|---|
| PEER | SIGNAL in either program | One-shot flag to the other sequencer. Waited on with WAIT PEER, tested with the PEER condition. Cleared when consumed |
| RW | MATCH_ADDR in the RX program | Direction bit captured with an address match. Readable by both programs |
| HELD | END with the hold bit in the TX program | The bus was left held (I2C: SCL low, no STOP). Cleared by the next TX program start, RELEASE or SET_PROTO |

The ACK bit of an I2C transfer no longer crosses between the FSMs: the TX program samples it itself with SAMPLE, which releases DOUT for one bit and captures DIN at the sample tick.

**2. Serializer.** Reads one bit per drive tick from the current byte at position `cnt` or `DATA_BITS − cnt` by BIT_ORDER. Loaded by NEXT_BYTE from the buffer or by LOAD_IMM from the program.

**3. Parity and CRC.** The same register structures as the receive side, computed over the bits sent by SHIFT_OUT while enabled. CRC_OUT shifts the register out; PARITY_OUT sends the parity bit and clears the accumulator.

**4. Bit stuffer.** After six consecutive 1s, inserts a 0. Enabled by BIT_STUFF.

**5. Line encoder.** NRZ passes through. NRZI toggles the line on a 0 and holds on a 1. Manchester emits two half-bits per bit: a 0 is high-then-low, a 1 is low-then-high.

**6. Bit timing.** With CLKED = 0 the phase counter from BIT_DIV produces the drive tick; CLK_RUN mirrors the counter onto the CLK slot, CLK_0 and CLK_1 set its level directly for START and STOP sequences, CLK_STOP freezes it. For Manchester, BIT_DIV counts half-bits. With CLKED = 1 the drive tick comes from the event detector.

**7. Pin driver.** Routes the data bit to the slot pins by role: DOUT alone, or DOUT and slot 1 driven complementary when DRIVE is differential. DRIVE_0, DRIVE_1 and DRIVE_IDLE set the line level directly; SEL_ON and SEL_OFF drive slot 3. Applies IDLE_LVL between messages and INVERT at the pad.

**Busy and lock**

| Mode | `tx_busy` (status) | `tx_lock` (rejects TRANSMIT, SET_PROTO, RELEASE) |
|---|---|---|
| Controller (MASTER = 1) | Program running | Same as `tx_busy` |
| Target (MASTER = 0) | Program running (armed or active) | Program running and it has executed LOCK since it started |

The default target programs execute LOCK once the external controller has committed to them: SPI after SEL asserts, I2C after the address match. A new TRANSMIT while armed but not locked replaces the response: the running program is stopped and restarted on the new buffer. With PERSIST the response re-arms from byte 0 after each transaction; without it the buffer empties after the first transaction, even if only part of it was consumed. NEXT_BYTE on an empty buffer in a target loads the FILL byte (0x00 or 0xFF by the FILL field) with no error.

**Interfaces**

| Signal | Dir | Meaning |
|---|---|---|
| `tx_load`, `tx_len[3:0]`, `tx_data[63:0]`, `tx_hold`, `tx_persist` | in | From the Controller |
| `tx_busy`, `tx_lock` | out | As defined above |
| PEER, RW, HELD | in / out | Shared with the RX sequencer as listed above |
| Event pulses, drive tick | in | From the event detector and bit timing |
| `pm_req`, `pm_addr[8:0]`, `pm_rdata[15:0]`, `pm_ack` | out / in | Instruction fetch |
| `pin_out[3:0]`, `pin_oe[3:0]` | out | Per slot, to the pin pool |

**Area estimate.** About 1.05K cell-equivalents per pinset counted as flops: sequencer ~400, buffer ~320, serializer and timing ~200, CRC and encoder ~150, minus the hard-wired framing that is gone. The buffer's latch saving is counted in the Integration area budget.

### Sequencer

File: `sequencer.sv`. Two instances per pinset, one inside `rx_fsm` and one inside `tx_fsm`.

The sequencer is a small interpreter. It fetches 16-bit instructions from the protocol memory, waits for events from the event detector and bit timing, and drives the primitives of its pipeline. It knows nothing about any protocol. The same module serves both directions; a parameter selects which operations and events are wired, and the unwired ones are no-ops.

**Instruction formats**

| Bits 15:14 | Format | Fields |
|---|---|---|
| `00` | ACT | `[13:10]` WAIT, `[9:5]` OP, `[4:0]` CNT |
| `01` | IMM | `[13:10]` IOP, `[9:8]` 0, `[7:0]` IMM |
| `10` | BR | `[13:9]` COND, `[8:6]` 0, `[5:0]` TARGET |
| `11` | — | Reserved. Executes as END |

An ACT instruction waits for its WAIT event, performs OP, and repeats both CNT times. IMM and BR execute in one cycle. TARGET is an instruction index within the program (0–55; 56–63 are out of range and execute as END).

**WAIT events**

| Code | Event | Code | Event |
|---|---|---|---|
| 0 | NONE: act at once | 8 | SEL_OFF |
| 1 | TICK: sample tick (RX) or drive tick (TX) | 9 | START |
| 2 | DIN_RISE | 10 | STOP |
| 3 | DIN_FALL | 11 | SE0 |
| 4 | DIN_EDGE | 12 | IDLE: CNT bit times with no DIN edge |
| 5 | CLK_RISE | 13 | PEER: the other sequencer signalled |
| 6 | CLK_FALL | 14–15 | Reserved |
| 7 | SEL_ON | | |

Any wait other than NONE also completes when an event in the current ENDS set fires; the instruction's OP is then skipped, remaining repeats are abandoned, and the ENDF flag is set. This is how a program notices the end of a frame without polling for it.

**CNT encoding**

| Value | Meaning |
|---|---|
| 0 | DATA_BITS (1–16, from the pinset register) |
| 1–27 | Literal |
| 28 | STOP bits: 1 or 2 (1.5 is sent as 2) |
| 29 | COUNT: the byte counter |
| 30 | CRC_LEN: 5, 16 or 32 by the selected CRC |
| 31 | Reserved |

**ACT operations**

| OP | Name | Effect |
|---|---|---|
| 0 | NOP | — |
| 1 | DRIVE_0 | DOUT low (open-drain: pull low) |
| 2 | DRIVE_1 | DOUT high (open-drain: release) |
| 3 | DRIVE_IDLE | DOUT to IDLE_LVL, hi-Z if DRIVE is hi-Z |
| 4 | SHIFT_OUT | Next serializer bit to DOUT. Parity, CRC and stuffer update |
| 5 | SHIFT_IN | Sample DIN into the deserializer. Parity, CRC and destuffer update |
| 6 | SAMPLE | TX: release DOUT for this bit and capture DIN at the sample tick. RX: capture DIN. Sets S |
| 7 | EMIT | Deserializer word to output staging; clear it |
| 8 | NEXT_BYTE | Next buffer byte to the serializer. Sets EMPTY if none; a target loads FILL |
| 9 | PARITY_OUT | Send the parity bit and clear the accumulator. Skips its wait when PARITY = none |
| 10 | PARITY_CHECK | Sample the parity bit; SET_ERR on mismatch. Skips its wait when PARITY = none |
| 11 | CRC_OUT | Shift one CRC bit out (use CNT = CRC_LEN) |
| 12 | CRC_CHECK | Compare the CRC register with the residue; SET_ERR on mismatch |
| 13 | FRAME_BEGIN | Open a message: snapshot the header, clear parity, stuffer and ENDF |
| 14 | FRAME_END | Close the message |
| 15 | SEL_ON | Slot 3 low |
| 16 | SEL_OFF | Slot 3 high |
| 17 | CLK_RUN | Slot 2 toggles with the bit timer |
| 18 | CLK_STOP | Slot 2 holds its level |
| 19 | CLK_0 | Slot 2 low |
| 20 | CLK_1 | Slot 2 high |
| 21 | TIMER_SYNC | Reload the bit timer to half a bit |
| 22 | SIGNAL | Set PEER for the other sequencer |
| 23 | SET_ERR | Error flag on the current message |
| 24 | LOAD_COUNT | Byte counter ← current serializer byte; sets ZERO |
| 25 | DEC_COUNT | Byte counter − 1; sets ZERO |
| 26 | STREAM_OUT | Repeat {TICK, SHIFT_OUT} with NEXT_BYTE every DATA_BITS bits until EMPTY or ENDF |
| 27 | STREAM_IN | Repeat {TICK, SHIFT_IN} with EMIT every DATA_BITS bits until ENDF |
| 28 | MATCH_ADDR | MATCH ← deserializer `[7:1]` == ADDR; RW ← deserializer `[0]` |
| 29 | LOCK | Target: `tx_lock` from now until END |
| 30 | ENDS | Set the frame-end set from CNT: `[4]` SE0, `[3]` SEL_OFF, `[2]` STOP, `[1:0]` IDLE: 0 off, 1 = 2, 2 = 8, 3 = 24 bit times. Clears ENDF |
| 31 | END | TX: stop, or re-arm when PERSIST and MASTER = 0. CNT`[0]` = 1 also sets HELD. RX: restart at 0 |

STREAM_OUT and STREAM_IN are the hot loops. They let a byte stream run without a fetch per bit or per byte, which is what makes SPI targets at 5 MHz and USB_LS possible through a shared memory port.

**IMM operations**

| IOP | Name | Effect |
|---|---|---|
| 0 | LOAD_IMM | Serializer ← IMM (a sync byte, preamble byte, fill) |
| 1 | MATCH_IMM | MATCH ← deserializer `[7:0]` == IMM |
| 2 | COUNT_IMM | Byte counter ← IMM |
| 3 | CRC_SEL | CRC ← IMM`[1:0]` (0 off, 1 CRC5, 2 CRC16, 3 CRC32); reset the register to all ones |
| 4–15 | — | Reserved, no-op |

**Branch conditions**

Even codes test the flag, odd codes its negation, except 0 = ALWAYS.

| Code | Flag | Set by |
|---|---|---|
| 0 | ALWAYS | — |
| 1–2 | S / !S | SAMPLE, PARITY_CHECK |
| 3–4 | MATCH / !MATCH | MATCH_IMM, MATCH_ADDR |
| 5–6 | EMPTY / !EMPTY | NEXT_BYTE |
| 7–8 | ZERO / !ZERO | LOAD_COUNT, COUNT_IMM, DEC_COUNT |
| 9–10 | MASTER / !MASTER | Pinset register |
| 11–12 | HOLD / !HOLD | TRANSMIT SUB bit 0 |
| 13–14 | HELD / !HELD | END with hold |
| 15–16 | RW / !RW | MATCH_ADDR |
| 17–18 | B0 / !B0 | Bit 0 of the current serializer byte (TX) or deserializer word (RX) |
| 19–20 | B1 / !B1 | Bit 1, likewise |
| 21–22 | ERR / !ERR | Error flag of the current message |
| 23–24 | ENDF / !ENDF | A frame-end event |
| 25–26 | PEER / !PEER | SIGNAL from the other sequencer |
| 27–28 | SEL / !SEL | Slot 3 level now (asserted = 1) |
| 29–30 | DIN / !DIN | DIN level now |
| 31 | — | Reserved, never taken |

**Execution and fetch**

Each sequencer holds a 6-bit PC, the current instruction, one prefetched instruction, a 5-bit repeat counter, an 8-bit byte counter and the flags above. The program base is `{slot, direction}`: TX programs start at word `0x70 × PROTO`, RX programs 56 words later. With PROTO = 7 the sequencer reads the built-in RAW program from constants instead of memory.

Fetches go through the protocol memory port, one 16-bit word each. The next sequential instruction is requested as soon as the current one starts executing, so straight-line code never waits. A taken branch requests its target and waits; worst case is about 12 cycles (up to 10 requesters round-robin, 1 cycle SRAM latency, 1 cycle return). Programs that need per-byte decisions at high bit rates use STREAM ops or keep the branch outside the bit loop.

A sequencer stops when VALID falls, on `buf_flush`, or (TX only) at END. Stopping returns DOUT, CLK and SEL to their idle levels and clears PEER, HELD and LOCK.

**Example: default UART programs**

TX program (9 instructions):

```
 0  ACT NONE     ENDS         0          ; no frame-end events
 1  ACT NONE     NEXT_BYTE               ; byte 0 → serializer
 2  ACT TICK     DRIVE_0                 ; start bit
 3  ACT TICK     SHIFT_OUT    DATA_BITS
 4  ACT TICK     PARITY_OUT              ; skipped when PARITY = none
 5  ACT TICK     DRIVE_1      STOP       ; stop bits
 6  ACT NONE     NEXT_BYTE
 7  BR  !EMPTY   → 2
 8  ACT NONE     END
```

RX program (15 instructions):

```
 0  ACT NONE     ENDS         IDLE=24    ; message ends after ~2 idle word times
 1  ACT DIN_FALL TIMER_SYNC              ; start edge; next sample tick lands mid-bit
 2  ACT TICK     SAMPLE                  ; middle of the start bit
 3  BR  S        → 1                     ; glitch, not a start bit
 4  ACT NONE     FRAME_BEGIN             ; opens the message on the first byte only
 5  ACT TICK     SHIFT_IN     DATA_BITS
 6  ACT TICK     PARITY_CHECK            ; skipped when PARITY = none
 7  ACT TICK     SAMPLE                  ; stop bit
 8  BR  S        → 10
 9  ACT NONE     SET_ERR                 ; framing error
10  ACT NONE     EMIT
11  ACT DIN_FALL TIMER_SYNC              ; next start edge, or idle timeout → ENDF
12  BR  !ENDF    → 2
13  ACT NONE     FRAME_END
14  BR  ALWAYS   → 1
```

The programs for SPI, I2C, USB_LS and ETH10 follow the same pattern; their sizes and the framing they implement are listed under Protocol Memory.

### Pinset Controller

Files: `pinset.sv` (×4), `pin_crossbar.sv` (shared).

The Pinset Controller has two parts: the shared pin pool, which owns the pads, and the per-pinset instance, which owns one channel.

**Pin pool (one instance)**

- Input path. Each of the 16 pool inputs passes a 2-flop synchronizer, the glitch filter of depth FILTER, and the INVERT XOR, producing `pin_in[15:0]`.
- Output path. For each pin, the owner's slot output and output enable are selected by OWNER. DRIVE converts them to `uio_out` / `uio_oe` as given in the I/O section. A pin whose owner is invalid, or that is unowned, takes its safe state.
- Crossbar. `pin_in[15:0]` goes to every pinset. Each pinset's four slot outputs come back with their target pin indices (ROLE_MAP), and a per-pin 4:1 select by OWNER picks the driver. Both directions are registered once.
- Ownership. Read from the per-pin registers. The pool itself never changes ownership.

**Pinset instance (four instances)**

Contains: the pinset register (see Register Bank), slot muxes, event detector, Translation FSM and Transmission FSM each with its sequencer, the shared PEER, RW and HELD flags, the 8-byte TX buffer and the 8-byte GUI buffer with its header snapshot (both latch-based, see Register Bank), dump enable flops and status flops.

| Signal | Dir | Meaning |
|---|---|---|
| `pin_in[15:0]` | in | From the pool |
| `slot_out[3:0]`, `slot_oe[3:0]` | out | Driven by the Transmission FSM, or IDLE_LVL when idle |
| `valid`, `ps_reg[63:0]` | — | Pinset register |
| `tx_load`, `tx_len`, `tx_data`, `tx_hold`, `tx_persist`, `gui_en`, `mem_en` | in | From the Controller |
| `rx_abort`, `buf_flush`, `valid_clr`, `ps_we`, `ps_word`, `ps_wdata` | in | From the Rewrite FSM |
| `tx_busy`, `tx_lock`, `rx_ovf` | out | Status |
| `gui_rec_valid`, `gui_hdr[23:0]`, `gui_data[63:0]`, `gui_len[3:0]`, `gui_flags[1:0]`, `gui_rec_take` | out / in | To the GUI Output Controller |
| `mem_push`, `mem_entry[10:0]` | out | To the Memory Output Controller: `{end, error, truncated, byte[7:0]}` |
| `pm_req[1:0]`, `pm_addr[1:0][8:0]`, `pm_rdata[15:0]`, `pm_ack[1:0]` | out / in | Instruction fetch, one request line per sequencer |

All four pinsets are identical and run any slot. The `FULL_PROTOCOLS` parameter stays in `pinset.sv` as the first area mitigation: setting it to 0 removes the Manchester encoder and decoder, the interval classifier, the destuffer and the CRC32 taps. Programs that use those primitives then stop working on that pinset; everything else is unchanged.

### Register Bank

Files: `pin_regs.sv` (16 global per-pin registers), pinset registers inside `pinset.sv`.

Each fact is stored once. Channel-level settings live in the pinset register. Pad behaviour and ownership live in the per-pin register of the physical pin.

**Pinset register, 64 bits, one per pinset**

| Bits | Field | Encoding |
|---|---|---|
| 63 | VALID | 0: FSMs idle, owned pads safe. 1: configuration in force |
| 62:60 | PROTO | Protocol slot 0–3 whose programs this pinset runs. 7: RAW, built in, no memory. 4–6: reserved, rejected by SET_PROTO |
| 59 | MASTER | 0 target, 1 controller |
| 58:57 | LINE_CODE | 00 NRZ, 01 NRZI, 10 Manchester, 11 reserved |
| 56:41 | BIT_DIV | System clocks per bit; per half-bit when Manchester |
| 40:37 | DATA_BITS | Data bits per frame minus 1 (1–16) |
| 36:35 | PARITY | 00 none, 01 even, 10 odd, 11 mark |
| 34:33 | STOP | 00 1, 01 1.5, 10 2, 11 reserved |
| 32 | BIT_ORDER | 0 LSB first, 1 MSB first |
| 31 | BIT_STUFF | 1: insert or strip a 0 after six 1s |
| 30:29 | CRC | 00 none, 01 CRC5, 10 CRC16, 11 CRC32 |
| 28 | CPOL | SPI clock idle polarity |
| 27 | CPHA | SPI clock phase |
| 26:25 | RX_SLOT | Slot the RX sequencer samples as DIN, 0–3 |
| 24 | FILL | Byte a target sends on buffer underflow: 0 = 0x00, 1 = 0xFF |
| 23:17 | ADDR | Own address compared by MATCH_ADDR |
| 16 | CLKED | 1: ticks come from the CLK slot edges (clocked target). 0: from the internal bit timer |
| 15:0 | ROLE_MAP | Slot 0 [3:0], slot 1 [7:4], slot 2 [11:8], slot 3 [15:12]; each a pool pin index |

The register is written as four 16-bit words: word 4 = [15:0], word 5 = [31:16], word 6 = [47:32], word 7 = [63:48], matching the template layout in the protocol memory.

Slot roles are fixed (slot 0 DOUT, 1 DIN, 2 CLK, 3 SEL; see the Translation FSM). Templates decide which pin each slot gets. In the default image:

| Template | Slot 0 (DOUT) | Slot 1 (DIN) | Slot 2 (CLK) | Slot 3 (SEL) | RX_SLOT | CLKED |
|---|---|---|---|---|---|---|
| UART | TX | RX | — | — | 1 | 0 |
| SPI controller | MOSI | MISO | SCLK | CS | 1 | 0 |
| SPI target | MISO | MOSI | SCLK | CS | 1 | 1 |
| I2C controller | SDA | SDA (same pin) | SCL | — | 1 | 0 |
| I2C target | SDA | SDA (same pin) | SCL | — | 1 | 1 |
| USB_LS | D+ | D− | — | — | 1 | 0 |
| ETH10 (overlay) | TX+ | TX− | RX+ | RX− | 2 | 0 |
| RAW | out | in | — | — | 1 | 0 |

**Per-pin register, 16 bits, one per pool pin**

| Bits | Field | Encoding |
|---|---|---|
| 15 | EN | 1: pin in use by OWNER |
| 14:13 | DIR | 00 in, 01 out, 10 bidir, 11 reserved |
| 12:11 | DRIVE | 00 push-pull, 01 open-drain, 10 differential, 11 hi-Z |
| 10 | IDLE_LVL | Line level when idle |
| 9 | INVERT | 1: invert at the pad |
| 8:7 | reserved | 0 |
| 6:3 | FILTER | Glitch filter depth, 0 = off |
| 2:1 | OWNER | Owning pinset, valid when EN = 1 |
| 0 | reserved | 0 |

**Write ports.** Only the Rewrite FSM writes. The pinset register accepts 16-bit word writes (word index 0–3 corresponding to template words 4–7). The per-pin registers accept full 16-bit writes by pin index. `valid_clr[X]` clears bit 63 of pinset X alone.

**Read ports.** Every field is readable in parallel by combinational logic. Nothing is copied into the FSMs.

**Storage.** VALID, EN and OWNER are reset flops. Every other field is a latch. Latches are instantiated from the PDK cells through a `cfg_latch` module (behavioural model under `` `ifdef SIM``), 16 bits per word, with each word's write enable passed through the PDK clock-gating cell. The latches are transparent during the low phase of `clk`; the Rewrite FSM drives their data from flops that change on the rising edge, so the data is stable throughout the transparent phase. A latch word is written only when nothing can be reading it: configuration while the pinset is invalid, buffers in the phases below. If the latch cells fail gate-level simulation, `cfg_latch` is rebuilt from flops with no other change.

**Latch-based buffers.** The TX buffer (64 bits) and the GUI buffer (64 data bits, 24-bit header snapshot, length and flags) of each pinset use the same `cfg_latch` words. Their writers and readers never overlap:

- TX buffer: written by the Controller in one cycle on TRANSMIT, which is refused while `tx_lock` is set. If a target program is running but not locked, the write first stops it and restarts it afterwards, so no sequencer reads the buffer during the write.
- GUI buffer: written by output staging one byte at a time; read by the GUI Output Controller only after the record is marked ready, at which point staging writes nothing until `gui_rec_take` returns the buffer.

The memory FIFO, the Controller's command buffer and the READ_MEM readback register stay as flops: each is written and read in the same cycles. Confirm the exact cell names in the `sg13cmos5l` library before writing `cfg_latch`; the sg13g2 equivalents are `sg13g2_dlhq_1` and `sg13g2_lgcp_1`.

### Protocol Memory

File: `protocol_mem.sv`. One instance: the SRAM macro, a port arbiter and the address map. It replaces the hard-wired template ROM and holds two things in one array, the protocol programs and the configuration templates, each at fixed addresses so the host, the Rewrite FSM and the sequencers all compute addresses the same way.

**Storage**

`RM_IHPSG13_1P_512x16_c2_bm_bist` from the IHP PDK: 512 words × 16 bits, single port, synchronous, registered read (address in one cycle, data out the next), per-bit write mask (unused: whole words are written), BIST pins tied off. 236.8 × 191.34 µm. Power pins on Metal4 only. The 16-bit word is the instruction width and the template word width, so nothing is packed or split. Under `` `ifdef SIM`` a behavioural array stands in for the macro; gate-level simulation uses the macro's own Verilog model. On an FPGA the same port maps onto inferred block RAM.

The memory is not reset and is undefined at power-up. The host loads it.

**Address map (16-bit words, 9-bit address)**

| Words | Blocks (4 words) | Content |
|---|---|---|
| `0x000`–`0x1BF` | 0–111 | Program bank: 4 protocol slots × 112 words |
| `0x1C0`–`0x1FF` | 112–127 | Template bank: 8 templates × 8 words |

The memory is fully allocated; there is no reserved space.

Protocol slot n occupies words `0x70·n` to `0x70·n + 0x6F`: the TX program at `+0x00` to `+0x37` (instruction i at `+i`) and the RX program at `+0x38` to `+0x6F`. Every slot has the same start and end, and both programs of every slot have the same length and offsets, so a program is written to the same place whatever else is loaded. Programs shorter than 56 instructions are padded with END (`0x03E0`). The slot base is 7 × 16 × n rather than a power of two; the sequencer forms it with one small adder.

Template t occupies words `0x1C0 + 8t` to `0x1C0 + 8t + 7`:

| Word | Content |
|---|---|
| 0–3 | Per-pin word for slot 0–3, in per-pin register format with EN set and OWNER = 0. A slot that claims no pin is `0x0000` |
| 4 | Pinset register [15:0], the default ROLE_MAP |
| 5 | Pinset register [31:16] |
| 6 | Pinset register [47:32] |
| 7 | Pinset register [63:48], with VALID stored as 0. PROTO names the protocol slot |

**Port and arbiter**

Ten requesters share the single port: eight sequencers (two per pinset), the Rewrite FSM, and the Controller (WRITE_MEM writes, READ_MEM reads). Each holds `pm_req` with `pm_addr` (and `pm_we`, `pm_wdata` for the Controller) until it sees its `pm_ack`. A round-robin arbiter grants one request per cycle. For a read, `pm_ack` returns with `pm_rdata` two cycles after the grant; for a write, one cycle after. Worst-case latency with all ten requesting is about 12 cycles; typical is 2–3, because sequencers fetch at most once per instruction and the other two requesters are idle almost always.

The port is the only path into the array. Nothing else can corrupt a program, and a slot in use is protected by the Controller's in-use check rather than by the memory.

**Default image, at 40 MHz**

| Index | Template | Slot | Default pins | BIT_DIV | Other fields |
|---|---|---|---|---|---|
| 0 | UART 115200 8N1 | 0 | TX P12, RX P8 | 347 | NRZ, DATA_BITS 7, LSB first, RX_SLOT 1 |
| 1 | SPI controller, mode 0, 1 MHz | 1 | MOSI P13, MISO P8, SCLK P12, CS P14 | 40 | MASTER, DATA_BITS 7, MSB first |
| 2 | SPI target, mode 0 | 1 | MISO P12, MOSI P9, SCLK P8, CS P10 | 40 | CLKED, DATA_BITS 7, MSB first, FILL 0 |
| 3 | I2C controller, 100 kHz | 2 | SDA P1 on slots 0 and 1, SCL P0 | 400 | MASTER, DATA_BITS 7, MSB first, open-drain |
| 4 | I2C target | 2 | SDA P1 on slots 0 and 1, SCL P0 | 400 | CLKED, ADDR 0 until overridden, open-drain, FILL 1 |
| 5 | USB_LS, 1.5 Mb/s | 3 | D+ P0, D− P1 | 27 | NRZI, BIT_STUFF, LSB first, differential, idle J |
| 6 | Placeholder | 6 | — | — | PROTO 6, so SET_PROTO rejects it until the ETH10 overlay replaces it |
| 7 | RAW | 7 (built in) | out P12, in P8 | 347 | NRZ, DATA_BITS 7, LSB first |

Pins are unchanged from the hard-wired design; only the slot each pin sits in follows the fixed slot roles now.

**ETH10 overlay.** `protocol_mem_eth10.hex` is 30 blocks: the ETH10 TX and RX programs for slot 3 (28 blocks, replacing USB_LS) and an ETH10 template for index 6 (2 blocks) with PROTO 3, pins TX+ P12, TX− P13, RX+ P8, RX− P9, BIT_DIV 6, Manchester, CRC32, LSB first, differential, RX_SLOT 2. The host loads it when it needs Ethernet framing and reloads the USB_LS blocks to go back. Nothing in hardware changes; the Manchester primitives stay in every pinset.

**UART template, as an example**

| Word | Value | Decoded |
|---|---|---|
| 0 | `0xA400` | TX: EN, out, push-pull, IDLE_LVL 1 |
| 1 | `0x9C18` | RX: EN, in, hi-Z, IDLE_LVL 1, FILTER 3 |
| 2–3 | `0x0000` | Unused |
| 4 | `0x008C` | ROLE_MAP: slot 0 = P12, slot 1 = P8 |
| 5 | `0x0200` | RX_SLOT 1 |
| 6 | `0xB6E0` | BIT_DIV[6:0] = 347 low bits, DATA_BITS 7 |
| 7 | `0x0002` | PROTO 0, BIT_DIV[15:7] |

Full register value: `0x0002_B6E0_0200_008C`.

**Default programs**

Sizes are from hand assembly against the instruction set and will move a little when the programs are written for real. The UART pair is listed in full under Sequencer.

| Slot | Protocol | TX program | RX program |
|---|---|---|---|
| 0 | UART | 9: start bit, data, parity, stop bits per byte | 15: start edge, confirm mid-bit, data, parity, stop check, idle end |
| 1 | SPI | ~10: controller: SEL_ON, CLK_RUN, STREAM_OUT, CLK_STOP, SEL_OFF. Target: wait SEL_ON, LOCK, STREAM_OUT | ~6: ENDS SEL_OFF; wait SEL_ON; FRAME_BEGIN; STREAM_IN; FRAME_END |
| 2 | I2C | ~52: controller: START or repeated START by HELD, address, ACK by SAMPLE, write loop with NACK abort, read loop with COUNT and ACK/NACK, STOP or hold by HOLD. Target: wait PEER, ACK, LOCK, then ACK each byte or shift bytes out until NACK | ~22: controller: on PEER, bytes of the read phase with the ACK clock skipped. Target: START, address, MATCH_ADDR, SIGNAL, bytes until STOP |
| 3 | USB_LS | ~16: LOAD_IMM 0x80, PID byte, CRC_SEL by B0 and B1, STREAM_OUT, CRC_OUT, EOP as SE0 for 2 bits then J | ~18: first edge, SYNC by MATCH_IMM 0x80, PID, CRC_SEL by class, STREAM_IN until SE0, CRC_CHECK |
| 3 (overlay) | ETH10 | ~14: COUNT_IMM 7 preamble loop of LOAD_IMM 0x55, LOAD_IMM 0xD5, CRC_SEL 3, STREAM_OUT, CRC_OUT | ~10: first edge, shift until MATCH_IMM 0xD5, CRC_SEL 3, STREAM_IN until idle, CRC_CHECK |
| 7 | RAW (built in) | 2: STREAM_OUT, END | 4: DIN_EDGE, TIMER_SYNC, FRAME_BEGIN, STREAM_IN until idle, FRAME_END |

Everything in the old per-protocol framing tables is now one of these programs. Adding a protocol is writing two more and a template, then 30 WRITE_MEM frames.

**Writing rules**

- WRITE_MEM writes whole 4-word blocks. A program is 14 blocks, a slot 28, a template 2.
- A program slot cannot be written while a valid pinset has PROTO equal to it. Templates can be written at any time the Rewrite FSM is idle.
- RAW (PROTO 7) never reads the memory, so it works before the image is loaded and after a bad upload.

**Generation.** `test/gen_protocol_mem.py` holds the template tables and an assembler for the mnemonics in the Sequencer section. It emits `protocol_mem_default.hex` (512 words) and `protocol_mem_eth10.hex` (the overlay), which the host firmware embeds and the cocotb testbench loads through WRITE_MEM frames or directly into the simulation model. The same Python module is the reference model's view of the image, so RTL and reference cannot disagree.

### GUI Output Controller

File: `dump_gui.sv`. One instance.

Sends each decoded message as a record on GUI_TX, a 1 Mbaud UART (BIT_DIV 40). Fields are separated by idle line time.

**Record format**

| Field | Size | Content |
|---|---|---|
| Protocol | 1 byte | `[7:5]` PROTO (protocol slot, 7 = RAW), `[4]` MASTER, `[3:2]` pinset, `[1]` error, `[0]` truncated |
| Blank | 1 character time (10 µs) | Idle line |
| Pins used | 2 bytes | ROLE_MAP, MSB first |
| Blank | 1 character time | Idle line |
| Message | 1–8 bytes | Decoded bytes, back to back |
| Blank, blank | 2 character times | End of record |

Example, pinset 3 in UART mode (TX P15, RX P11) receiving "Hi":

```
0C  <blank>  00 BF  <blank>  48 69  <blank><blank>
```

`0C` is slot 0 (UART), target role, pinset 3, no flags. The host maps slot numbers to names from the image it loaded.

**Behaviour**

- Each pinset holds one complete record (header snapshot, up to 8 bytes, flags) in latches. A record is sent only when complete, so no gaps appear inside a field.
- A round-robin arbiter picks the next ready record. A record with N message bytes takes N + 7 character times, 10 µs each.
- `gui_rec_take` releases the pinset's buffer when its last byte has been loaded into the serializer.
- `dump_pending` in the status byte is set while any record is ready or being sent.

**Receiver note.** A PC serial driver discards inter-byte timing. The RP2040 on the demo board reads GUI_TX, timestamps gaps (above 0.5 character times is a separator, above 1.5 is end of record), and forwards parsed records to the PC.

### Memory Output Controller

File: `dump_mem.sv`. One instance.

Streams messages as fixed 8-byte memory slots, so that a receiver writing bytes to consecutive addresses recovers message boundaries from the address alone: slot index = address ÷ 8.

**Memory slot format**

| Byte | Content |
|---|---|
| 0–6 | Up to 7 message bytes, in order. Unused bytes are 0x00 |
| 7 | Trailer: `[7:6]` pinset, `[5:3]` byte count 1–7, `[2]` error, `[1]` truncated, `[0]` continued |

A message longer than 7 bytes fills consecutive slots; every slot but the last has continued = 1. The trailer comes last so the controller can stream bytes as they arrive and needs only a 3-bit counter; nothing is buffered beyond the FIFO.

**Behaviour**

- MEM_DATA carries bits MSB first. MEM_CLK toggles once per bit at 10 MHz and holds low when idle, including between bytes of a slow message. Alignment is by count, not time.
- A 16-entry FIFO holds `{end, error, truncated, data[7:0]}` entries pushed by the source pinset. The current source ID is a register in the controller, set by DUMP_CTRL.
- On each data entry the serializer sends the byte. After the 7th byte of a slot with the message still open, it sends a trailer with continued = 1. On an entry with end set, it sends that byte, pads the slot with 0x00, and sends the trailer.
- Only one pinset may have memory dump enabled. DUMP_CTRL enforces this and flushes the FIFO when the source changes, so bytes of two sources never share a slot.
- A full FIFO drops the entry and sets that pinset's `rx_ovf`. The next trailer reports truncated.
- MEM_RESET stops MEM_CLK, discards the partial slot and the FIFO contents, and restarts at a slot boundary.

Throughput: 8 output bytes per 7 message bytes, about 1.1 MB/s of message data at 10 MHz.

Receiver: RP2040 PIO shifting in on MEM_CLK with 8-bit autopush and DMA into RAM, or a shift register and a divide-by-8 counter producing a byte strobe into an external SRAM with an address counter.

---

## Integration

### Module hierarchy

```
tt_um_coms_emu_js_JCDM         project.v       Tiny Tapeout wrapper, ties ena, renames pins
└── protoemu_top               protoemu_top.sv
    ├── controller             controller.sv   Controller top, wiring only
    │   ├── host_spi           host_spi.sv     Receiver, MISO
    │   └── cmd_decode         cmd_decode.sv   Decoder, status register
    ├── rewrite_fsm            rewrite_fsm.sv
    ├── protocol_mem           protocol_mem.sv Port arbiter, address map, SRAM macro wrapper
    │   └── RM_IHPSG13_1P_512x16_c2_bm_bist    PDK macro; behavioural model under `ifdef SIM`
    ├── pin_regs               pin_regs.sv     16 per-pin registers
    ├── pin_crossbar           pin_crossbar.sv Pin pool: sync, filter, pad logic
    ├── pinset[0..3]           pinset.sv       FULL_PROTOCOLS = 1
    │   ├── cfg_latch          cfg_latch.sv    Pinset register and buffer words
    │   ├── event_det          primitives.sv   Also sync2, glitch_filter, bit_timer, crc_reg
    │   ├── bit_timer          primitives.sv
    │   ├── rx_fsm             rx_fsm.sv       Receive primitives
    │   │   └── sequencer      sequencer.sv    RX interpreter
    │   └── tx_fsm             tx_fsm.sv       Transmit primitives
    │       └── sequencer      sequencer.sv    TX interpreter
    ├── dump_gui               dump_gui.sv
    └── dump_mem               dump_mem.sv
pe_pkg                         pe_pkg.sv       Op codes, instruction encodings, enums, field widths, CRC residues
```

`info.yaml` lists `pe_pkg.sv` first, then the rest. `project.v` stays a thin wrapper so the design can be simulated or run on an FPGA without the Tiny Tapeout interface. On an FPGA the SRAM macro is replaced by inferred block RAM behind the same `protocol_mem` port.

### Area budget

Cell-equivalents, 1 flop ≈ 3.5. Estimates are ±30%.

| Block | Cell-eq | Change from the hard-wired design |
|---|---|---|
| 4 × pinset (RX ~1.45K, TX ~1.05K, register, buffers, slot mux, status, shared flags) | 14.4K | +0.8K: two sequencers (~400 each) replace the framing FSMs (~750), plus flags, ENDS and the RX_SLOT mux |
| Per-pin registers, sync, filters | 1.1K | −0.1K: advisory PULL field removed |
| Pin pool crossbar and pad logic | 1.0K | — |
| Rewrite FSM | 0.4K | −0.3K: ROM constants and the 64-bit word staging gone, port handshake added |
| Protocol memory port: arbiter, address and data muxes, readback register | 0.4K | new |
| Controller | 1.2K | +0.2K: WRITE_MEM, READ_MEM, in-use check |
| GUI and memory output | 2.0K | — |
| Latch-based configuration and buffers (saving) | −1.1K | −0.6K: TX and GUI buffers as latches |
| Subtotal | 19.4K | +0.4K |
| With 12% clock tree and hold buffers | ~21.7K | |
| SRAM macro, 1.45 tiles plus routing halo, as tile-equivalent | ~1.85K | new |
| Total | ~23.6K | |
| Budget | 24K | |

The estimate is about 2% under budget, well inside its ±30% error. Mitigations in order if synthesis runs high: `FULL_PROTOCOLS` = 0 on all pinsets (about −1.2K; the ETH10 slot then has no primitives to run on), 2-bit FILTER and 12-bit BIT_DIV (about −0.4K), 4-byte GUI buffers (about −0.6K), three pinsets (about −3.6K). Decide after the first synthesis run, not before.

What the SRAM buys: 8 Kbit of writable storage. The same bits as latches would cost about 20K cell-equivalents, so without the macro the design could hold at most one writable slot alongside hard-wired defaults. A hard-wired copy of the default image as a boot ROM would cost about 1.5–2K and is not planned; the host loads the image.

### Timing

- Every stage of each FSM is one register deep. The longest paths are the slot muxes (16:1 from the crossbar) and the per-pin output select (4:1 by OWNER). Both are registered.
- `CLOCK_PERIOD` 25 ns, `PL_TARGET_DENSITY_PCT` 50 in `src/config.json`. The macro is placed with `MACROS` / `PDN` settings in the same file; its power pins are on Metal4 only, which the LibreLane PDN must bridge.
- The SRAM runs on `clk`. Its read is registered: address in one cycle, data the next. The macro's Liberty timing must be checked against the 25 ns period once the flow runs; the `A_DLY` pin selects a slower, safer timing mode if needed.
- Instruction fetch is not on any bit-rate critical path by construction: STREAM ops run without fetches, and a taken branch costs at most about 12 cycles. The slowest acceptable bit for a program with a branch at every byte boundary is about 12 cycles, i.e. 3.3 Mbit/s.
- Manchester framing at 10 Mbit/s (BIT_DIV 2) is out of reach for a program; the primitives can decode it but the sequencer cannot keep up at frame transitions. ETH10 is kept as an overlay for framing work at BIT_DIV ≥ 6.

### Bring-up on the demo board

1. Set the project clock to 40 MHz.
2. Wire the RP2040 as SPI host: SCK to `ui_in[0]`, MOSI to `ui_in[1]`, CS_n to `ui_in[2]`, MISO from `uo_out[0]`.
3. Jumper `uo_out[7]` to `ui_in[7]` (P15 to P11).
4. Load the image: 128 WRITE_MEM frames from `protocol_mem_default.hex`. Read a few blocks back with READ_MEM.
5. Send `1C 03`: pinset 3, UART, offset 3 (TX P15, RX P11). Send `00` and check status is `0x00`.
6. Send `2D`: GUI dump on, pinset 3.
7. Send `3C 02 48 69`: transmit "Hi".
8. Read GUI_TX at 1 Mbaud. Expect `0C`, gap, `00 BF`, gap, `48 69`, double gap.

Before the image exists, `1C 7x`-style RAW setups (template 7, built in) work without any memory contents and prove the pins, the host port and the dump outputs.

---

## Known Limitations

- One protocol per pinset. Four UARTs on one pinset are not possible.
- Four role slots. SPI with more than one chip select does not fit.
- Messages are limited to 8 bytes per TRANSMIT and per GUI record. Ethernet's 64-byte minimum frame cannot be sent. I2C reads are the exception: up to 255 bytes.
- Memory dump serves one pinset at a time. Each memory slot carries at most 7 message bytes.
- The GUI output carries about 100 KB/s, below sustained 10BASE-T rates.
- The host port carries about 500 KB/s of TRANSMIT payload.
- ETH10 at 10 Mbit/s is not reachable by a program; the ETH10 overlay is specified for BIT_DIV ≥ 6. There is no link pulse support.
- USB_LS BIT_DIV 27 has a 1.2% rate error, inside tolerance but with reduced margin. There is no fractional BIT_DIV. The default USB_LS RX program does not check the PID complement.
- I2C clock stretching, multi-controller arbitration and 10-bit addressing are not supported by the default programs, and there is no register field for a 10-bit address.
- The protocol memory is volatile. The host must load the image after every power-up before any SET_PROTO other than RAW. There is no boot ROM.
- A protocol slot cannot be rewritten while a valid pinset runs it. Release or reconfigure the pinset first.
- A program is at most 56 instructions per direction, and can only use the primitives that exist: NRZ, NRZI and Manchester line codes, three CRC polynomials, bit stuffing after six 1s, four slots, one byte counter. A protocol outside that set (CAN arbitration, 1-Wire pulse widths, a second chip select) needs new primitives, not just a new program.
- Four protocol slots, and the memory is fully allocated. PROTO 4–6 are rejected. ETH10 is not resident by default; loading its overlay displaces USB_LS from slot 3 until the host writes USB_LS back.
- A target-mode response waits indefinitely for the external controller. There is no timeout; the host replaces or releases it.
- An I2C controller holding the bus after a HOLD message keeps SCL low until the next TRANSMIT, RELEASE or SET_PROTO.
- No programmable pulls; fit external resistors. P12–P15 cannot tri-state.
- The status byte reports only the most recent command.
- The 64-bit pinset register is fully allocated.
