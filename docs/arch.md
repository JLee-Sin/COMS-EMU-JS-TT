# SoC/IP Approach to Communication Protocol Emulation

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
   - [Register Bank](#Register-Bank)
   - [Protocol ROM](#Protocol-ROM)
   - [GUI Output Controller](#GUI-Output-Controller)
   - [Memory Output Controller](#Memory-Output-Controller)
5. [Integration](#Integration)
6. [Known Limitations](#Known-Limitations)

---

## Introduction

This chip emulates serial communication protocols on programmable pins. It has four independent pinsets. Each pinset can be switched at runtime to UART, SPI, I2C, low-speed USB, or 10BASE-T Ethernet, as either the controller or the target side where the protocol has one. A host configures the chip and sends messages over a dedicated SPI port. Received traffic is decoded on chip and sent out on a GUI output for live viewing and on a memory output for capture.

**Target**

| Item | Value |
|---|---|
| Platform | Tiny Tapeout, `ttihp-verilog-template` branch `cmos5l` |
| Process | IHP 130 nm SG13CMOS5L, 5 metal layers |
| Tile size | 6 × 4 (about 0.7 mm², about 24K cell-equivalents) |
| System clock | 40 MHz (`CLOCK_PERIOD` = 25 ns) |
| Flow | LibreLane via the Tiny Tapeout GDS action |
| Simulation | cocotb on Icarus Verilog; gate-level sim after hardening |

**Design principles**

- One clock domain. Every external signal is synchronized into the 40 MHz domain and processed by edge detection. No signal from a pin is ever used as a clock.
- Configuration is atomic. A pinset never runs on a partly written configuration. Its VALID bit is cleared before any change and set as the final write.
- Pins are owned. Sixteen physical pins form a pool. A pinset claims pins through its role map, each pin has at most one owner, and only the owner can drive it.
- Commands commit on CS_n rise. A host command runs only after its whole frame has arrived. A truncated or malformed frame changes nothing.
- Reject rather than corrupt. A command that would break an invariant is refused whole and reported in the status byte.
- Shared primitives, per-protocol sequencers. Shift registers, line coders, CRC, parity and bit timing are configured by registers. Only a small sequencer per protocol knows framing rules.

**Terminology**

| Term | Meaning |
|---|---|
| Host | The external SPI controller that commands the chip. On the demo board, the RP2040. |
| Pinset | One of four emulation channels (ID 0–3). |
| Pool pin | One of 16 physical pins P0–P15 shared by all pinsets. |
| Slot | One of four entries in a pinset's role map. |
| Role | What a slot means for the current protocol (TX, SCLK, SDA, D+ ...). |
| Template | A ROM entry holding the registers for one protocol configuration. |
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
                    │       │        │
            ┌───────▼──┐    │   ┌────▼──────────┐
            │Rewrite   │    │   │ Protocol ROM  │
            │FSM       ◄────┼───┤ 8 templates   │
            └───┬──────┘    │   └───────────────┘
                │ writes    │ TRANSMIT, DUMP_CTRL, MEM_RESET
      ┌─────────▼──────────▼───────────────────────────┐
      │ Register Bank: 4 pinset regs + 16 per-pin regs │
      └─────────┬──────────────────────────────────────┘
                │
   ┌────────────▼─────────────────────────────────────┐
   │ Pinset Controller ×4                             │
   │   slot mux · event detector · Translation FSM    │
   │   Transmission FSM · TX buffer · GUI buffer      │
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
| 3:2 | PS | Pinset ID 0–3. Ignored by NOP, READ_STATUS, MEM_RESET |
| 1:0 | SUB | Sub-op. Used by DUMP_CTRL and TRANSMIT, else 0 |

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
| `0x7`–`0xF` | Reserved | — | — | Always rejected, bad frame |

### NOP

Frame `0x00`. Returns the status byte and clears the reported error bits. No other effect.

### SET_PROTO

Loads a template into pinset PS.

| Byte | Content |
|---|---|
| 0 | `0x1`, PS, `00` |
| 1 | `[7:5]` template index, `[4]` override present, `[3:0]` pin offset |
| 2–3 | Override value V, MSB first. Present only when byte 1 bit 4 is set |

Template indices: 0 UART, 1 SPI controller, 2 SPI target, 3 I2C controller, 4 I2C target, 5 USB_LS, 6 ETH10, 7 RAW.

The pin offset is added to every enabled slot of the template's ROLE_MAP. It moves the whole protocol as a block.

The override value V means different things by template:

| Template | V |
|---|---|
| UART, SPI controller, I2C controller, USB_LS, ETH10, RAW | BIT_DIV, system clocks per bit (per half-bit for ETH10) |
| SPI target | Ignored. The external controller supplies the clock |
| I2C target | `[9:0]` own address (7-bit address in `[6:0]`), `[10]` ADDR10, `[15:11]` 0 |

Validation happens before any change:

1. Busy if pinset PS is actively transmitting (`tx_lock`) or the Rewrite FSM is active.
2. For each enabled slot, target pin = template slot + offset. Pin conflict if the target is above P15 or owned by another pinset.
3. Incapable pin if the role needs a capability the target pin does not have (see I/O, pool capabilities).

On success the Rewrite FSM runs the sequence in its section and the pinset goes live in about 10–40 cycles. On failure nothing changes.

Examples: `1C 03` sets pinset 3 to UART with offset 3 (TX P15, RX P11). `1C 13 10 47` does the same at 9600 baud (BIT_DIV 4167). `14 90 00 50` sets pinset 1 to I2C target at address 0x50.

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
| I2C controller, read (byte 0 bit 0 = 1) | 7-bit address in `[7:1]`, 1 in `[0]` | Byte 1 = number of bytes to read, 1–255. N must be 2 |
| I2C target | Data | Data. Sent when the external controller reads from the pinset's address |
| USB_LS | PID in `[3:0]` | Packet payload. SYNC, PID complement, CRC and EOP are added |
| ETH10 | Data | Data. Preamble, SFD and CRC32 are added |
| RAW | Data | Data. Sent on slot 0 with no framing |

For an I2C controller read the decoder checks N = 2 and count ≠ 0 using the pinset's PROTO and MASTER; a violation is a bad frame. Bytes read from the target go to the dump outputs as one message, the same as any receive.

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
| `00` | Bad frame | Wrong byte count, partial last byte, buffer overflow, reserved op, TRANSMIT length 0 or above 8, I2C read with N ≠ 2 or count 0 |
| `01` | Pin conflict | Target pin owned by another pinset, or offset pushes a slot past P15 |
| `10` | Incapable pin | Role needs a capability its pin lacks |
| `11` | Busy | Rewrite in progress, `tx_lock` set, TRANSMIT to an invalid pinset |

Bits 7:5 clear after they have been shifted out once. The status byte holds the result of the most recent command only. A host confirms a command by following it with a NOP or by reading the status returned with its next command. A host that sends frames faster than it checks status can miss a failure; READ_STATUS shows the resulting state.

### Command latency

At 5 MHz SCK each byte takes 1.6 µs (64 cycles).

| Command | Bytes | Transfer | Execute | Total |
|---|---|---|---|---|
| NOP, DUMP_CTRL, RELEASE, MEM_RESET | 1 | 1.6 µs | 1–40 cycles | ~1.7–2.6 µs |
| SET_PROTO | 2 | 3.2 µs | 10–40 cycles | ~3.5–4.2 µs |
| SET_PROTO with override | 4 | 6.4 µs | 10–40 cycles | ~6.7–7.4 µs |
| TRANSMIT, 8 bytes | 10 | 16 µs | 1 cycle, then line time | ~16 µs to start |

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
| PULL | Advisory only. Tiny Tapeout pads have no programmable pulls. Fit external resistors |
| FILTER | Glitch filter in logic, after a 2-flop synchronizer. Depth 0–15 cycles |

### Electrical notes

- Logic levels only. Real USB needs its own differential levels and pull-up signalling; real 10BASE-T needs magnetics and about ±2.5 V differential drive. Use external transceivers or loop back between two pinsets.
- I2C lines need external pull-ups (4.7 kΩ is typical).
- Every pool input passes a 2-flop synchronizer before any logic. Add FILTER cycles on top. Keep FILTER well below a bit period: at most 3 for USB_LS, 0 for Ethernet.

### Host SPI timing

| Parameter | Limit | Reason |
|---|---|---|
| SCK frequency | ≤ 5 MHz | MISO is updated 2–3 cycles after the detected falling edge and must be valid at the next rising edge |
| SCK high and low time | ≥ 100 ns | At least two system clocks per phase so no edge is missed |
| CS_n fall to first SCK rise | ≥ 100 ns | Status bit 7 is loaded on CS_n fall and must reach MISO first |
| Last SCK fall to CS_n rise | ≥ 100 ns | The last bit must be captured before commit |
| CS_n high between frames | ≥ 100 ns | Both CS_n edges must be detected |

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
- `ena` is ignored.

---

## IPs

### Controller

Files: `host_spi.sv`, `cmd_decode.sv`.

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
5. MISO shift register. Loaded with the status byte on `cs_fall`; bit 7 is driven at once. Each `sck_fall` shifts out the next bit. After the header the register holds 0, except during READ_STATUS when it is reloaded with each readback byte.

**Decoder, on `cs_rise`**

1. Reject as bad frame if the bit counter is not 0, the overflow flag is set, OP is reserved, or the byte count does not match OP. For TRANSMIT, also check N against the byte count and, when pinset PS is an I2C controller and payload byte 0 bit 0 is 1, that N = 2 and payload byte 1 ≠ 0.
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

3. Latch the result into the status register. For Rewrite FSM commands the result arrives on `rw_done` / `rw_err` some cycles later, long before the next frame can complete.

**Interfaces**

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `rw_req`, `rw_op`, `rw_ps`, `rw_tmpl`, `rw_ovr`, `rw_val`, `rw_offset` | out | 1, 1, 2, 3, 1, 16, 4 | Request to the Rewrite FSM |
| `rw_busy`, `rw_done`, `rw_err` | in | 1, 1, 2 | Rewrite FSM status and result |
| `tx_load[3:0]`, `tx_len[3:0]`, `tx_data[63:0]`, `tx_hold`, `tx_persist` | out | — | TRANSMIT payload and flags to the pinsets |
| `gui_en[3:0]`, `mem_en[3:0]` | out | — | Dump enables |
| `mem_reset` | out | 1 | To the Memory Output Controller |
| `valid[3:0]`, `tx_busy[3:0]`, `tx_lock[3:0]`, `rx_ovf[3:0]`, `proto[3:0][2:0]`, `master[3:0]`, `dump_pending`, `owned[15:0]` | in | — | Status inputs |

**Timing.** The TRANSMIT copy takes one cycle. The next frame cannot complete its first byte for about 64 cycles, so no double buffering of the command buffer is needed.

### Rewrite FSM

File: `rewrite_fsm.sv`. One instance, shared by all pinsets.

The Rewrite FSM is the only writer of the register bank. It streams a template from the Protocol ROM into a pinset's registers, applies the override, and enforces pin ownership and capability rules.

**States**

```
IDLE → CHECK → INVALIDATE → FLUSH → SETTLE → RELEASE_PINS → WRITE_PINS → WRITE_CHANNEL → DONE
                   │
                   └── reject → DONE (rw_err set, nothing written)
```

**Sequence for SET_PROTO**

1. CHECK. Reject busy if `tx_lock[PS]`. For each enabled slot in the template, read the slot's ROLE_MAP nibble from ROM word 4 and add the offset. Reject with pin conflict if the sum exceeds 15 or if `pin_en[target] && owner[target] != PS`. Reject with incapable pin if the slot's DIR or DRIVE (from the template's per-pin word) is not allowed on the target pin. The check takes four cycles.
2. INVALIDATE. Clear `valid[PS]`. The pinset's FSMs return to idle; its pads go to the safe state.
3. FLUSH. Assert `rx_abort[PS]` and `buf_flush[PS]` for one cycle. A partial received message is marked truncated and dropped. An armed response is dropped.
4. SETTLE. Wait 2 cycles so registered pad outputs show safe values before any pin register changes.
5. RELEASE_PINS. For each pin with `pin_en && owner == PS` that is not a target of the new map, clear EN and OWNER. One pin per cycle, 16 cycles maximum.
6. WRITE_PINS. Stream ROM words 0–3. For each enabled slot, write the word into per-pin register `target` with OWNER set to PS and EN set. One word per cycle.
7. WRITE_CHANNEL. Stream ROM words 4–7 into pinset register PS, one word per cycle, with patches:
   - Word 4: add the offset to each enabled ROLE_MAP nibble.
   - Word 5: if `rw_ovr` and the template is I2C target, set bits `[10:1]` to V`[9:0]` and bit `[0]` to V`[10]`.
   - Words 6–7: if `rw_ovr` and the template is not SPI target or I2C target, replace BIT_DIV (register bits 56:41: word 6 bits `[15:9]` hold BIT_DIV`[6:0]`, word 7 bits `[8:0]` hold BIT_DIV`[15:7]`).
   - Word 7: force bit 15 (VALID) to 1. This is the last write.
8. DONE. Pulse `rw_done` with `rw_err`.

**Sequence for RELEASE**

Step 1 (busy check only), then steps 2–4, then clear EN and OWNER on every pin with `owner == PS`, then DONE. The Controller clears the dump enables.

**Interfaces**

| Signal | Dir | Meaning |
|---|---|---|
| Request bus from Controller | in | As listed under Controller |
| `rom_addr[5:0]`, `rom_data[15:0]` | out, in | `{template, word}` to the Protocol ROM |
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
          → [5] check + shift → [6] framing sequencer → [7] output staging
```

Stages 2–5 are shared primitives. Stage 6 is the only protocol-specific logic.

**1. Slot mux**

Selects the four slot signals `s0`–`s3` from the 16 pool inputs using the ROLE_MAP nibbles (four 16:1 muxes). The outputs are registered; this is the likely critical path. Which slot acts as data, clock and select depends on PROTO and MASTER:

| PROTO, MASTER | Data in | Clock in | Select / aux |
|---|---|---|---|
| UART | s1 (RX) | — | — |
| SPI, controller | s2 (MISO) | own SCLK | — |
| SPI, target | s1 (MOSI) | s0 (SCLK) | s3 (CS) |
| I2C, either | s1 (SDA) | s0 (SCL) | — |
| USB_LS | s0 (D+), s1 (D−) | — | — |
| ETH10 | s2 (RX+), s3 (RX−) | — | — |
| RAW | s1 | — | — |

**2. Event detector**

Stores each slot's previous value and produces one-cycle pulses: data rise and fall, clock rise and fall, CS assert and deassert, I2C START (SDA falls while SCL high) and STOP (SDA rises while SCL high), USB SE0 (D+ and D− both low). The SPI sampling edge is chosen by CPOL and CPHA. The Transmission FSM uses the same pulses in target modes, so there is one detector per pinset.

**3. Bit timing**

Produces `bit_valid` and the sampled level. Three modes:

- Clocked (SPI, I2C): `bit_valid` is the sampling edge event, gated by CS for SPI. I2C ignores the sampling edge in the cycle of a START or STOP.
- Asynchronous (UART, USB_LS, RAW): a 16-bit phase counter. On a UART or RAW start edge, or on any USB data edge, the counter reloads to BIT_DIV/2. It emits a sample and reloads to BIT_DIV−1 when it reaches 0. This is enough for UART, which realigns on every start bit, and for USB_LS, where bit stuffing guarantees an edge at least every 7 bits (worst-case drift about 8% of a bit with BIT_DIV 27).
- Manchester (ETH10): an interval counter measures cycles between edges. Short intervals (under 3 cycles) are half-bit; long intervals are full-bit. A flag tracks whether the next edge is mid-bit. Each mid-bit edge emits one bit: rising is 1, falling is 0.

After a frame the same counter measures idle time: UART and RAW end after 2 word times with no start edge, USB end after SE0 of about 2 bit periods, Ethernet end after about 1.5 bit periods without a transition.

**4. Line decode**

- NRZ: the sampled level is the bit.
- NRZI (USB): no change from the previous J/K state is 1, a change is 0.
- Manchester: the bit from stage 3.

The destuffer (enabled by BIT_STUFF) counts consecutive 1s. After six, the next bit is dropped; if that bit is a 1, a stuff error is flagged.

**5. Check and shift**

- CRC: one right-shifting register with a selectable polynomial, reflected form, covers CRC5, CRC16 and CRC32. It is initialized to all ones at frame start and runs over every received bit including the CRC field. At frame end the register is compared with the width's fixed residue. The sequencer never needs to locate the CRC field. Residue constants come from the USB 2.0 and IEEE 802.3 specifications.
- Parity: one flop XORs each data bit; the parity slot is checked against PARITY.
- Deserializer: each bit is written to position `cnt` (LSB first) or `DATA_BITS − cnt` (MSB first) of a 16-bit word. `word_done` fires when `cnt == DATA_BITS`. The word clears at frame start.

**6. Framing sequencer**

One FSM with a shared state set. PROTO and MASTER select the transitions.

| State | UART / RAW | SPI | I2C controller | I2C target | USB_LS | ETH10 |
|---|---|---|---|---|---|---|
| IDLE → SYNC | Start edge | CS asserted | TX reports `tx_phase` ≠ idle | START | First J→K | Transitions begin |
| SYNC | Confirm start bit mid-bit (UART only) | — | — | — | Match SYNC | Match preamble, then SFD |
| HEADER | — | — | Sample ACK after the address byte, report `rx_ack_in` | Address byte. Compare to ADDR; mismatch → wait for STOP | PID byte. Check complement; select CRC5 or CRC16 | — |
| DATA | DATA_BITS bits | DATA_BITS clocks | Write phase: sample ACK after each byte. Read phase: deserialize 8 bits | 8 bits | Bytes | Bytes |
| CHECK | Parity, stop bit (UART only) | — | Read phase: raise `rx_byte_done`; TX drives ACK or NACK | Raise `rx_byte_done`; TX drives ACK | — | — |
| END | Idle timeout | CS deasserted | TX reports idle or bus held | STOP | SE0, then CRC residue | Carrier lost, then CRC residue |

In I2C controller write phases and I2C target read phases, the Translation FSM produces no message; it only samples ACK bits. In SPI controller mode it captures MISO during the pinset's own transmission; the captured bytes form a received message.

Framing, parity, stuff, PID and CRC errors set flags on the current message. If VALID drops mid-frame, the sequencer returns to IDLE and marks the message truncated.

**7. Output staging**

- At frame start: snapshot PROTO, MASTER and ROLE_MAP for the record header.
- Each byte: write to the GUI buffer if `gui_en` and push `{end, error, truncated, byte}` to the memory FIFO if `mem_en`.
- At frame end or when 8 bytes have accumulated: mark the GUI record ready. A longer message continues in a new record with the same header.
- If the GUI buffer is still full from the previous record: drop the byte and set `rx_ovf`.

**Area estimate (cell-equivalents)**

| Block | Per pinset |
|---|---|
| Event detector | ~150 |
| Bit timing | ~300 |
| Line decode + destuffer | ~100 |
| CRC + parity | ~190 |
| Deserializer | ~200 |
| Framing sequencer | ~350 |
| Output staging | ~100 |
| Total | ~1.4K |

**Latency.** About 5–6 cycles from a pin edge to a decoded bit. The tightest target-mode deadline is SPI target MISO at 1 MHz (500 ns half period, about 3× margin). SPI target tops out near 5 MHz SCLK.

### Transmission FSM

File: `tx_fsm.sv`. One instance per pinset.

The Transmission FSM encodes a message from the TX buffer and drives it onto the pinset's pins. In controller modes it runs as soon as a message is loaded. In target modes it arms the message and waits for the external controller.

```
TX buffer → [1] framing sequencer → [2] serializer → [3] parity / CRC → [4] bit stuffer
          → [5] line encoder → [6] bit timing → [7] pin driver
```

**1. Framing sequencer.** Reads bytes from the TX buffer and adds protocol framing:

| Protocol | Before data | Per byte | After data |
|---|---|---|---|
| UART | — | Start bit, DATA_BITS bits, parity, STOP bits | — |
| SPI controller | CS low | DATA_BITS clocks | CS high after the last bit |
| SPI target | Wait for CS assert | Shift on the non-sampling edge | — |
| I2C controller, write | START (or repeated START if the bus is held), address + W, sample ACK | 8 bits, sample ACK. NACK aborts: STOP, error flag | STOP, or hold SCL low if HOLD |
| I2C controller, read | START (or repeated START), address + R, sample ACK | RX deserializes; TX drives ACK, or NACK on the last byte | STOP, or hold if HOLD |
| I2C target | Wait for address match from RX | Write: drive ACK after each byte. Read: shift out a buffer byte, sample ACK; NACK ends | Release SDA |
| USB_LS | SYNC (`0x80` sent LSB first), PID + PID complement | Data bytes | CRC5 or CRC16 by PID class, EOP (SE0 for 2 bits, then J for 1 bit) |
| ETH10 | 7 × `0x55` preamble, `0xD5` SFD | Data bytes | CRC32, then idle |
| RAW | — | Bits at BIT_DIV, no framing | — |

**I2C handshake between the two FSMs**

| Signal | From | Meaning |
|---|---|---|
| `tx_phase[1:0]` | TX | idle, addr, write, read. Also tells RX when a controller transaction is in progress |
| `rx_ack_in` | RX | ACK bit sampled on the 9th clock, valid with `rx_ack_valid` |
| `rx_addr_match`, `rx_rw` | RX | Target mode: own address seen, with the direction bit |
| `rx_byte_done` | RX | A byte has been received; the ACK slot is next |
| `rx_stop` | RX | STOP seen |
| `tx_ack_drive` | TX | Level to drive on SDA in the ACK slot (0 = ACK) |

**2. Serializer.** Reads one bit per `bit_valid` from the current byte at position `cnt` or `DATA_BITS − cnt` by BIT_ORDER.

**3. Parity and CRC.** The same register structures as the receive side, computed over the data bits as they are sent. The CRC is appended by shifting the register out after the last data byte.

**4. Bit stuffer.** After six consecutive 1s, inserts a 0. Enabled by BIT_STUFF.

**5. Line encoder.** NRZ passes through. NRZI toggles the line on a 0 and holds on a 1. Manchester emits two half-bits per bit: a 0 is high-then-low, a 1 is low-then-high.

**6. Bit timing.** In controller modes a phase counter from BIT_DIV produces `bit_valid` and, for SPI and I2C, generates the clock on the clock slot. For Manchester, BIT_DIV counts half-bits. In target modes `bit_valid` comes from the event detector.

**7. Pin driver.** Routes the data bit to the slot pins by role: a single data slot, or a differential pair driven complementary. Applies IDLE_LVL between messages and INVERT at the pad.

**Busy and lock**

| Mode | `tx_busy` (status) | `tx_lock` (rejects TRANSMIT, SET_PROTO, RELEASE) |
|---|---|---|
| Controller | From load until the last bit leaves the pins | Same as `tx_busy` |
| Target | Armed or active | Active only: CS asserted (SPI) or address match to STOP (I2C) |

A new TRANSMIT while armed replaces the response. With PERSIST the response re-arms from byte 0 after each transaction; without it the buffer empties after the first transaction, even if only part of it was consumed. Underflow sends 0 (SPI target) or 0xFF (I2C target) with no error.

**Interfaces**

| Signal | Dir | Meaning |
|---|---|---|
| `tx_load`, `tx_len[3:0]`, `tx_data[63:0]`, `tx_hold`, `tx_persist` | in | From the Controller |
| `tx_busy`, `tx_lock` | out | As defined above |
| I2C handshake signals | in / out | As listed above |
| Event pulses | in | From the event detector in target modes |
| `pin_out[3:0]`, `pin_oe[3:0]` | out | Per slot, to the pin pool |

**Area estimate.** About 1.0K cell-equivalents per pinset: sequencer ~400, buffer ~320, serializer and timing ~200, CRC and encoder ~150.

### Pinset Controller

Files: `pinset.sv` (×4), `pin_crossbar.sv` (shared).

The Pinset Controller has two parts: the shared pin pool, which owns the pads, and the per-pinset instance, which owns one channel.

**Pin pool (one instance)**

- Input path. Each of the 16 pool inputs passes a 2-flop synchronizer, the glitch filter of depth FILTER, and the INVERT XOR, producing `pin_in[15:0]`.
- Output path. For each pin, the owner's slot output and output enable are selected by OWNER. DRIVE converts them to `uio_out` / `uio_oe` as given in the I/O section. A pin whose owner is invalid, or that is unowned, takes its safe state.
- Crossbar. `pin_in[15:0]` goes to every pinset. Each pinset's four slot outputs come back with their target pin indices (ROLE_MAP), and a per-pin 4:1 select by OWNER picks the driver. Both directions are registered once.
- Ownership. Read from the per-pin registers. The pool itself never changes ownership.

**Pinset instance (four instances)**

Contains: the pinset register (see Register Bank), slot muxes, event detector, Translation FSM, Transmission FSM, the 8-byte TX buffer, the 8-byte GUI buffer with its header snapshot, dump enable flops and status flops.

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

All four pinsets are built with the full protocol set. The `FULL_PROTOCOLS` parameter stays in `pinset.sv` so that pinsets can be made lite later without an RTL change (it removes the USB_LS and ETH10 sequencers, the interval classifier, SE0 detection, SYNC and SFD matching, the destuffer and the CRC32 taps), but every instance sets it to 1.

### Register Bank

Files: `pin_regs.sv` (16 global per-pin registers), pinset registers inside `pinset.sv`.

Each fact is stored once. Channel-level settings live in the pinset register. Pad behaviour and ownership live in the per-pin register of the physical pin.

**Pinset register, 64 bits, one per pinset**

| Bits | Field | Encoding |
|---|---|---|
| 63 | VALID | 0: FSMs idle, owned pads safe. 1: configuration in force |
| 62:60 | PROTO | 000 RAW, 001 UART, 010 SPI, 011 I2C, 100 USB_LS, 101 ETH10, 110–111 reserved |
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
| 26:17 | ADDR | I2C own address when MASTER = 0. 7-bit address in [23:17] |
| 16 | ADDR10 | 0 7-bit, 1 10-bit |
| 15:0 | ROLE_MAP | Slot 0 [3:0], slot 1 [7:4], slot 2 [11:8], slot 3 [15:12]; each a pool pin index |

The register is written as four 16-bit words: word 4 = [15:0], word 5 = [31:16], word 6 = [47:32], word 7 = [63:48], matching the Protocol ROM layout.

Slot meaning by PROTO (unused slots are ignored):

| PROTO | Slot 0 | Slot 1 | Slot 2 | Slot 3 |
|---|---|---|---|---|
| UART | TX | RX | — | — |
| SPI | SCLK | MOSI | MISO | CS |
| I2C | SCL | SDA | — | — |
| USB_LS | D+ | D− | — | — |
| ETH10 | TX+ | TX− | RX+ | RX− |
| RAW | out | in | — | — |

**Per-pin register, 16 bits, one per pool pin**

| Bits | Field | Encoding |
|---|---|---|
| 15 | EN | 1: pin in use by OWNER |
| 14:13 | DIR | 00 in, 01 out, 10 bidir, 11 reserved |
| 12:11 | DRIVE | 00 push-pull, 01 open-drain, 10 differential, 11 hi-Z |
| 10 | IDLE_LVL | Line level when idle |
| 9 | INVERT | 1: invert at the pad |
| 8:7 | PULL | 00 none, 01 up, 10 down, 11 reserved. Advisory |
| 6:3 | FILTER | Glitch filter depth, 0 = off |
| 2:1 | OWNER | Owning pinset, valid when EN = 1 |
| 0 | reserved | 0 |

**Write ports.** Only the Rewrite FSM writes. The pinset register accepts 16-bit word writes (word index 0–3 corresponding to ROM words 4–7). The per-pin registers accept full 16-bit writes by pin index. `valid_clr[X]` clears bit 63 of pinset X alone.

**Read ports.** Every field is readable in parallel by combinational logic. Nothing is copied into the FSMs.

**Storage.** VALID, EN and OWNER are reset flops. Every other field is a latch. Latches are instantiated from the PDK cells through a `cfg_latch` module (behavioural model under `` `ifdef SIM``), 16 bits per word, with each word's write enable passed through the PDK clock-gating cell. The latches are transparent during the low phase of `clk`; the Rewrite FSM drives their data from flops that change on the rising edge, so the data is stable throughout the transparent phase. Latches are written only while their pinset is invalid, so nothing reads a transparent latch. If the latch cells fail gate-level simulation, `cfg_latch` is rebuilt from flops with no other change. Confirm the exact cell names in the `sg13cmos5l` library before writing `cfg_latch`; the sg13g2 equivalents are `sg13g2_dlhq_1` and `sg13g2_lgcp_1`.

### Protocol ROM

File: `template_rom.sv`. Hardwired constants, one instance.

Eight entries of eight 16-bit words, addressed by `{template[2:0], word[2:0]}`.

| Word | Content |
|---|---|
| 0–3 | Per-pin word for role slot 0–3, in per-pin register format with EN set and OWNER = 0. Unused slots are `0x0000` |
| 4 | Pinset register [15:0], the default ROLE_MAP |
| 5 | Pinset register [31:16] |
| 6 | Pinset register [47:32] |
| 7 | Pinset register [63:48], with VALID stored as 0 |

Streaming words 0 to 7 writes the pins before the channel register.

**Default per template, at 40 MHz**

| Index | Template | Default pins | BIT_DIV | Other fields |
|---|---|---|---|---|
| 0 | UART 115200 8N1 | TX P12, RX P8 | 347 | NRZ, DATA_BITS 7, LSB first |
| 1 | SPI controller, mode 0, 1 MHz | SCLK P12, MOSI P13, MISO P8, CS P14 | 40 | MASTER, DATA_BITS 7, MSB first |
| 2 | SPI target, mode 0 | SCLK P8, MOSI P9, MISO P12, CS P10 | 40 | DATA_BITS 7, MSB first |
| 3 | I2C controller, 100 kHz | SCL P0, SDA P1 | 400 | MASTER, DATA_BITS 7, MSB first, open-drain |
| 4 | I2C target | SCL P0, SDA P1 | 400 | ADDR 0 until overridden, open-drain |
| 5 | USB_LS, 1.5 Mb/s | D+ P0, D− P1 | 27 | NRZI, BIT_STUFF, LSB first, differential, idle J |
| 6 | ETH10 | TX+ P12, TX− P13, RX+ P8, RX− P9 | 2 | Manchester, CRC32, LSB first, differential |
| 7 | RAW | out P12, in P8 | 347 | NRZ, DATA_BITS 7, LSB first |

**UART entry, as an example**

| Word | Value | Decoded |
|---|---|---|
| 0 | `0xA400` | TX: EN, out, push-pull, IDLE_LVL 1 |
| 1 | `0x9C98` | RX: EN, in, hi-Z, IDLE_LVL 1, PULL up, FILTER 3 |
| 2–3 | `0x0000` | Unused |
| 4 | `0x008C` | ROLE_MAP: slot 0 = P12, slot 1 = P8 |
| 5 | `0x0000` | — |
| 6 | `0xB6E0` | BIT_DIV[6:0] = 347 low bits, DATA_BITS 7 |
| 7 | `0x1002` | PROTO UART, BIT_DIV[15:7] |

Full register value: `0x1002_B6E0_0000_008C`.

**Generation.** The eight entries are generated by `test/gen_rom.py` from one Python table. The script emits `template_rom.sv` and the same table is imported by the cocotb testbench, so RTL and reference model cannot disagree.

### GUI Output Controller

File: `dump_gui.sv`. One instance.

Sends each decoded message as a record on GUI_TX, a 1 Mbaud UART (BIT_DIV 40). Fields are separated by idle line time.

**Record format**

| Field | Size | Content |
|---|---|---|
| Protocol | 1 byte | `[7:5]` PROTO, `[4]` MASTER, `[3:2]` pinset, `[1]` error, `[0]` truncated |
| Blank | 1 character time (10 µs) | Idle line |
| Pins used | 2 bytes | ROLE_MAP, MSB first |
| Blank | 1 character time | Idle line |
| Message | 1–8 bytes | Decoded bytes, back to back |
| Blank, blank | 2 character times | End of record |

Example, pinset 3 in UART mode (TX P15, RX P11) receiving "Hi":

```
2C  <blank>  00 BF  <blank>  48 69  <blank><blank>
```

**Behaviour**

- Each pinset holds one complete record (header snapshot, up to 8 bytes, flags). A record is sent only when complete, so no gaps appear inside a field.
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
coms_emu_js_tt_JCDM            project.v       Tiny Tapeout wrapper, ties ena, renames pins
└── protoemu_top               protoemu_top.sv
    ├── host_spi               host_spi.sv     Controller: receiver, MISO
    ├── cmd_decode             cmd_decode.sv   Controller: decoder, status register
    ├── rewrite_fsm            rewrite_fsm.sv
    ├── template_rom           template_rom.sv Generated
    ├── pin_regs               pin_regs.sv     16 per-pin registers
    ├── pin_crossbar           pin_crossbar.sv Pin pool: sync, filter, pad logic
    ├── pinset[0..3]           pinset.sv       FULL_PROTOCOLS = 1
    │   ├── cfg_latch          cfg_latch.sv    Pinset register words
    │   ├── event_det          primitives.sv
    │   ├── rx_fsm             rx_fsm.sv
    │   └── tx_fsm             tx_fsm.sv
    ├── dump_gui               dump_gui.sv
    └── dump_mem               dump_mem.sv
pe_pkg                         pe_pkg.sv       Op codes, enums, field widths, CRC residues
```

`info.yaml` lists `pe_pkg.sv` first, then the rest. `project.v` stays a thin wrapper so the design can be simulated or run on an FPGA without the Tiny Tapeout interface.

### Area budget

Cell-equivalents, 1 flop ≈ 3.5. Estimates are ±30%.

| Block | Cell-eq |
|---|---|
| 4 × pinset (RX ~1.4K, TX ~1.0K, register, buffers, slot mux, status) | 13.6K |
| Per-pin registers, sync, filters | 1.2K |
| Pin pool crossbar and pad logic | 1.0K |
| Rewrite FSM and ROM | 0.7K |
| Controller | 1.0K |
| GUI and memory output | 2.0K |
| Latch-based configuration (saving) | −0.5K |
| Subtotal | 19.0K |
| With 12% clock tree and hold buffers | ~21.3K |
| Budget | 24K |

Mitigations if the real numbers run high, in order: lite pinsets 2–3 (`FULL_PROTOCOLS` = 0, about −2.4K), drop ETH10, 2-bit FILTER and 12-bit BIT_DIV, SRAM for buffers.

### Timing

- Every stage of each FSM is one register deep. The longest paths are the slot muxes (16:1 from the crossbar) and the per-pin output select (4:1 by OWNER). Both are registered.
- `CLOCK_PERIOD` 25 ns, `PL_TARGET_DENSITY_PCT` 50 in `src/config.json`.
- ETH10 at 40 MHz has 2 samples per half-bit. It is a stretch goal and may be dropped if timing or area fails.

### Bring-up on the demo board

1. Set the project clock to 40 MHz.
2. Wire the RP2040 as SPI host: SCK to `ui_in[0]`, MOSI to `ui_in[1]`, CS_n to `ui_in[2]`, MISO from `uo_out[0]`.
3. Jumper `uo_out[7]` to `ui_in[7]` (P15 to P11).
4. Send `1C 03`: pinset 3, UART, offset 3 (TX P15, RX P11). Send `00` and check status is `0x00`.
5. Send `2D`: GUI dump on, pinset 3.
6. Send `3C 02 48 69`: transmit "Hi".
7. Read GUI_TX at 1 Mbaud. Expect `2C`, gap, `00 BF`, gap, `48 69`, double gap.

---

## Known Limitations

- One protocol per pinset. Four UARTs on one pinset are not possible.
- Four role slots. SPI with more than one chip select does not fit.
- Messages are limited to 8 bytes per TRANSMIT and per GUI record. Ethernet's 64-byte minimum frame cannot be sent. I2C reads are the exception: up to 255 bytes.
- Memory dump serves one pinset at a time. Each memory slot carries at most 7 message bytes.
- The GUI output carries about 100 KB/s, below sustained 10BASE-T rates.
- The host port carries about 500 KB/s of TRANSMIT payload.
- ETH10 receive has only 2× oversampling per half-bit at 40 MHz and no link pulse support. It is a stretch goal.
- USB_LS BIT_DIV 27 has a 1.2% rate error, inside tolerance but with reduced margin. There is no fractional BIT_DIV.
- I2C clock stretching, multi-controller arbitration and 10-bit addressing are not supported. ADDR10 is stored but ignored.
- A target-mode response waits indefinitely for the external controller. There is no timeout; the host replaces or releases it.
- An I2C controller holding the bus after a HOLD message keeps SCL low until the next TRANSMIT, RELEASE or SET_PROTO.
- PULL is advisory. P12–P15 cannot tri-state.
- The status byte reports only the most recent command.
- The 64-bit pinset register is fully allocated.
