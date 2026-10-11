# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Tiny Tapeout ASIC project (template `ttihp-verilog-template`, branch `cmos5l`, IHP SG13CMOS5L 130 nm, 6×4 tiles): a communication protocol emulator with four runtime-programmable "pinsets", commanded by a host over SPI. Protocols are microcode programs (UART, SPI, I2C and USB low-speed in the default image; Ethernet framing as a loadable overlay) held in a host-loaded on-chip SRAM, run by a small sequencer in each pinset over shared primitives.

**Current state: the design exists only as a spec.** `docs/arch.md` is the complete architecture document and the source of truth. `src/project.v`, `test/tb.v` and `test/test.py` still hold the Tiny Tapeout template logic (an adder), with only the top module renamed to `tt_um_coms_emu_js_JCDM`. Implementing RTL means building what `docs/arch.md` describes; read the relevant section of it before writing any module.

## Competition context

This is an entry for Jane Street's protocol emulator ASIC competition (https://blog.janestreet.com/protocol-emulator-asic-competition/, questions to asic-competition@janestreet.com). Rules as published there, checked 2026-10-10:

- Brief: an open-source, general-purpose protocol emulator ASIC. UART, SPI and I2C first; low-speed USB and 10 Mbit Ethernet are stretch goals; JTAG, SWD, PS/2 and CAN are suggested extras.
- The chip should be **reprogrammable so new protocols can be supported after fabrication**, within its timing and I/O limits. The cited reference architectures are RP2040 PIO and TI Sitara PRU cores. Prizes go to the "most novel designs", in functionality or in design/verification methodology.
- Process and template: IHP 130 nm CMOS5L through Tiny Tapeout, starting from `ttihp-verilog-template` branch `cmos5l` (this repo), with `tiles: "6x4"` in `info.yaml`. 6x4 is the current maximum; 8x4 is under consideration and would be announced by email to sign-ups.
- Area guidance: budget about 1K logic cells per tile, synthesize early, leave room for clock tree and routing. SRAM can beat flops for instruction memory (`tt_um_urish_sram_test` is the Tiny Tapeout example).
- Any HDL and any verification method is allowed. Trying the RTL on an FPGA first is suggested.
- Submissions must be open source. Deadline **18 January 2027**; the submission form will be added to the blog page nearer the time. Winners are taped out on the March 2027 CMOS5L shuttle.

## Tiny Tapeout rules that constrain the RTL

- The top module name must start with `tt_um_` and be unique (convention: include a GitHub username). `tt-support-tools` rejects `info.yaml` otherwise. The **file** name is free: `project.v` can keep its name as long as it is listed in `source_files`.
- The top module's port list must match the template exactly (`ui_in`, `uo_out`, `uio_in`, `uio_out`, `uio_oe`, `ena`, `clk`, `rst_n`), and every output must be driven.
- SystemVerilog `.sv` files are accepted: the tools read every source with Yosys `read_verilog -sv`, hand them to LibreLane as `VERILOG_FILES`, and lint with Verilator. The limit is Yosys's SystemVerilog subset, not Verilator's or Icarus's, so write to that subset (`logic`, `always_ff`/`always_comb`, `typedef enum`/`struct packed`, packages referenced as `pe_pkg::NAME`). Avoid `import pkg::*`, interfaces, classes and unpacked-array ports until a GDS run has shown they synthesize.
- `test/Makefile` passes `-g2012` to Icarus so the `.sv` sources compile as SystemVerilog.

## Commands

All simulation runs from `test/` (cocotb 2.0 on Icarus Verilog; `pip install -r test/requirements.txt`, plus `iverilog`).

```sh
cd test
make -B                                  # RTL simulation, all tests
make -B COCOTB_TEST_FILTER=test_project  # single test (regex on test name)
make -B GATES=yes                        # gate-level sim; needs test/gate_level_netlist.v and PDK_ROOT
make -B FST=                             # dump VCD instead of FST (also change $dumpfile in tb.v)
gtkwave tb.fst tb.gtkw                   # or: surfer tb.fst
```

`make` exits 0 even when a test fails. Check the result the way CI does: `! grep failure results.xml`.

Hardening (GDS), precheck, gate-level test and docs are run by GitHub Actions (`.github/workflows/`, all pinned to `TinyTapeout/tt-gds-action@ihp-cmos5l` with `pdk: ihp-sg13cmos5l`) on every push. The devcontainer clones `tt-support-tools` into `./tt` and installs LibreLane for local hardening. Lint/format tooling per `.vscode/settings.json`: Verilator for lint, `verible-verilog-format` for formatting; LibreLane also runs its linter during hardening (`RUN_LINTER` in `src/config.json`).

## Things that must be kept in sync

Adding or renaming a source file or the top module touches several places at once:

- `info.yaml` `source_files` (one entry per file, all under `src/`) and `top_module` (currently `tt_um_coms_emu_js_JCDM`, defined in `src/project.v`)
- `test/Makefile` `PROJECT_SOURCES`
- `test/tb.v` module instantiation
- The pinout in `info.yaml` duplicates the pin map in `docs/arch.md` (I/O section) and `docs/info.md`

`docs/info.md` is the public datasheet built by the docs action; `docs/arch.md` is the internal design spec.

## Known gaps between the spec and the repo

These are unresolved; resolve them deliberately rather than copying one side blindly.

- **RTL files are scaffolds.** Every `.sv` file in `src/` has a header comment, a module declaration with its port list derived from the arch.md interface tables, and no logic (`pe_pkg.sv` has its constants). Port names and packing conventions (per-pinset vectors packed four wide, `proto` as `[11:0]`, `owner` as `[31:0]`) are the contract between files; change them in the spec and every neighbour together. All files are listed in `info.yaml` `source_files` and `test/Makefile` `PROJECT_SOURCES` (same order in both, `pe_pkg.sv` first).
- **Area is estimated at 23.6K of 24K cell-eq** including the macro (±30%). The spec lists mitigations in order; do not apply any until a synthesis run gives real numbers.
- **Clock.** Spec is 40 MHz: `CLOCK_PERIOD` 25 and `PL_TARGET_DENSITY_PCT` 50 in `src/config.json`, which currently has 20 and 60. `info.yaml` `clock_hz` is 0. The template test drives a 100 kHz clock.
- **Devcontainer PDK.** `.devcontainer/Dockerfile` sets `PDK=ihp-sg13g2`; CI and the gate-level Makefile paths use `ihp-sg13cmos5l`.
- **`test/gen_protocol_mem.py` does not exist yet.** The spec says it holds the template tables plus an assembler for the sequencer mnemonics and emits `protocol_mem_default.hex`, which the testbench and host firmware both load. Programs and templates are never hand-edited as hex.
- **SRAM macro integration is unproven here.** `protocol_mem.sv` wraps `RM_IHPSG13_1P_512x16_c2_bm_bist` (IHP PDK, 236.8 × 191.3 µm). The CMOS5L precheck accepts SRAM marker layers since Sept 2026, but `src/config.json` has no `MACROS`/PDN settings yet, the macro's Metal4-only power pins need a PDN bridge, and its Liberty timing at 25 ns is unchecked.
- **Latch cell names.** `cfg_latch` wraps PDK latch and clock-gate cells; the spec only knows the sg13g2 names and says to confirm the sg13cmos5l equivalents first. It needs a behavioural model under `` `ifdef SIM`` (the gate-level Makefile defines `SIM`, `FUNCTIONAL`, `GL_TEST`).

## Architecture (from `docs/arch.md`)

Data flow: host SPI → **Controller** (`controller` wrapping `host_spi` and `cmd_decode`) → **Rewrite FSM** reading templates from **Protocol Memory** (`protocol_mem`, one SRAM macro behind a 10-requester round-robin port) → **Register Bank** → 4 × **Pinset Controller** (each with an RX and a TX pipeline of shared primitives, each driven by a `sequencer` instance fetching its program from the same memory) ↔ shared **pin crossbar** → pads; decoded bytes → **GUI Output** (`uo_out[1]`, 1 Mbaud UART records) and **Memory Output** (`uo_out[3:2]`, fixed 8-byte slots).

`project.v` is meant to stay a thin Tiny Tapeout wrapper around `protoemu_top` so the core can be simulated or put on an FPGA without the TT interface.

Invariants that span modules and are easy to break:

- **Single clock domain.** Every external signal goes through a 2-flop synchronizer and is handled by edge detection in the 40 MHz domain. No pin is ever used as a clock.
- **Rewrite FSM is the only writer of the register bank.** Pinset config changes only while that pinset's VALID is 0; VALID is cleared first and set by the very last write (template word 7, bit 15 forced to 1).
- **Pin ownership.** 16 pool pins: P0–P7 = `uio[7:0]` (bidir), P8–P11 = `ui_in[7:4]` (input only), P12–P15 = `uo_out[7:4]` (output only, cannot tri-state). Each pin has at most one owning pinset; I2C and USB_LS roles must land on P0–P7.
- **Commit on CS_n rise.** A host frame (1 header byte `{OP[3:0], PS[1:0], SUB[1:0]}` + up to 9 payload bytes, MSB first) executes only once complete; malformed frames change nothing, and a command that would break an invariant is rejected whole and reported in the status byte.
- **Template/register layout coupling.** A template is 8 × 16-bit words at `0x1C0 + 8t`: words 0–3 are per-pin registers for slots 0–3, words 4–7 are the 64-bit pinset register `[15:0]`…`[63:48]`. The Rewrite FSM patches words 4–7 (pin offset into ROLE_MAP, BIT_DIV or ADDR override chosen by the host via SET_PROTO SUB) as it streams them, so field positions in the register table, the image generator, and the patch logic must agree.
- **No protocol knowledge outside the programs.** The Controller, Rewrite FSM, primitives and sequencer must not special-case UART/SPI/I2C/USB. Anything protocol-specific belongs in a program in `gen_protocol_mem.py` or in a register field. Slot roles are fixed (0 DOUT, 1 DIN, 2 CLK, 3 SEL, plus RX_SLOT); PROTO is a slot index 0–3, 7 = built-in RAW.
- **Fixed memory geometry.** Slot n = words `0x70·n`…`+0x6F`, TX program at +0, RX at +0x38, 56 instructions each, padded with END `0x03E0`. The 512-word memory is fully allocated. WRITE_MEM writes 4-word blocks and is refused for a slot a valid pinset is running. The memory is volatile; the host loads the image after power-up.
- **Latch storage depends on disjoint phases.** Configuration words, the TX buffer and the GUI buffer are latches (`cfg_latch`) and are only written when nothing reads them (pinset invalid; TRANSMIT refused while locked; GUI record read only after ready). The memory FIFO, command buffer and READ_MEM readback register must stay flops. Any new concurrent reader or writer of a latch word is a bug.
- **Fetch latency is a design constraint.** A taken branch costs up to ~12 cycles through the shared port; per-bit and per-byte loops must use STREAM_OUT/STREAM_IN, never a branch.
- **`tx_busy` vs `tx_lock`.** Identical in controller modes; in target modes `tx_busy` means armed-or-active while `tx_lock` (which rejects TRANSMIT / SET_PROTO / RELEASE) is active-only.

Area is estimated at ~23.6K against a 24K cell-equivalent budget (21.7K standard cells plus ~1.85K for the SRAM macro); the spec's Integration section lists the mitigation order (`FULL_PROTOCOLS = 0` on all pinsets first, then FILTER/BIT_DIV width, GUI buffers, pinset count) and Known Limitations lists what is intentionally unsupported.
