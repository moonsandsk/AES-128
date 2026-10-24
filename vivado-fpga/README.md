# Pipelined AES-128 Encryption Engine on the Basys 3

A fully pipelined AES-128 encryption core with an FSM controller and board I/O, targeting the Digilent Basys 3 (Xilinx Artix-7 XC7A35T, part `xc7a35tcpg236-1`). See the [main README](../README.md) for an overview.

**Authors:** Aditi Chandra and Akanksha Venkatesh

## What it does

Set a plaintext byte on switches SW0 to SW7 and flip SW15 up. The byte is replicated 16 times into a 128-bit block (`{16{sw}}`), encrypted with a fixed 128-bit master key, and the low byte of the ciphertext appears on LEDs LD0 to LD7.

The master key is `2b7e151628aed2a6abf7158809cf4f3c`, the example key from FIPS-197 and NIST SP 800-38A, so results can be checked against any AES implementation.

## Files

```
vivado-fpga/
├── build_aes_basys3.tcl            Vivado flow: create project, simulate, synthesise, implement, bitstream, program
├── rtl/
│   ├── aes_pkg.v                   aes_sbox: 256-entry S-box LUT
│   ├── aes_round_function.v        one combinational round: SubBytes, ShiftRows, MixColumns, AddRoundKey
│   ├── aes_encrypt_128_pipeline.v  10-stage pipelined core + aes_key_expand_step
│   ├── PasswordManagerFPGA.sv      FSM / handshake controller
│   └── PasswordManagerDemo.sv      top level: synchronisers, debounce, edge detect, LED registers
├── sim/
│   └── tb_PasswordManagerDemo.sv   self-checking testbench (board level + core level)
├── constraints/
│   └── PasswordManagerFPGA.xdc     Basys 3 pins, 100 MHz clock, false paths, bitstream settings
└── results/
    ├── simulation_log.txt          full output of the 175-check testbench run
    ├── timing_summary.rpt          Vivado post-route timing summary
    └── utilization.rpt             Vivado post-route utilisation
```

Hierarchy:

```
PasswordManagerDemo
└── PasswordManagerFPGA
    └── aes_encrypt_128_pipeline
        ├── aes_key_expand_step  (x10)
        └── aes_round_function   (x10)
            └── aes_sbox         (x16 per round)
```

## Architecture

### Pipelined core

- **10 register stages, one per AES round.** Each stage holds a 128-bit state register. The longest combinational path is now a single round instead of all ten, which is what allows 100 MHz.
- The initial AddRoundKey (plaintext XOR K0) is folded into the front of stage 1, so no 11th register is needed. The core's inputs therefore come straight from flip-flops (the controller's plaintext register).
- Round 10 skips MixColumns through the `is_final_round` input of the round function, as FIPS-197 specifies.
- **Throughput:** one 128-bit block per clock, 12.8 Gbit/s at 100 MHz. **Latency:** 10 clocks.

### Valid tracking

A 1-bit valid token travels down the pipeline next to the data, so `out_valid` is aligned with its ciphertext by construction rather than by a separate counter that could drift. The controller adds a debug `pipe_stage` counter (1 to 10) and a simulation-only assertion that fires if the latency is ever not exactly 10.

### Key schedule: the `STATIC_KEY` parameter

- `STATIC_KEY = 1` (used on the board): the round keys are derived combinationally from a constant key, so synthesis folds the whole key schedule into constants. This saves about 1,150 flip-flops and 40 S-boxes.
- `STATIC_KEY = 0` (general mode): a second 10-stage pipeline computes round keys alongside the data, so every block can carry its own key and the key can change on every clock. This mode nearly fills the XC7A35T, so the board build uses `STATIC_KEY = 1`. The testbench exercises both modes.

### S-box

The table was generated from the mathematical definition (multiplicative inverse in GF(2⁸) modulo x⁸+x⁴+x³+x+1, followed by the affine transform with constant 0x63) and checked to be a bijection. Generating the table avoids transcription errors.

### Controller handshake

| Signal | Meaning |
|---|---|
| `input_valid` | one-cycle request; accepted only when not busy |
| `busy` | high from acceptance until the result is delivered |
| `output_valid` | one-cycle pulse in the cycle the new ciphertext appears |
| `done` | level, high from `output_valid` until the next request |
| `ciphertext` | held stable until the next result |

Timing for a request accepted on edge T: T+1 the block enters the core, T+11 it leaves round 10, T+12 the result register updates and `output_valid` / `done` go high.

### Reset and board I/O

- Only valid bits and control registers are reset (active-low, synchronous). The wide datapath registers have no reset, following Xilinx UG949 guidance; their contents are ignored while the valid bits are low.
- BTNC is active-high on the Basys 3, so the top level takes `btn_reset`, synchronises and debounces it, and inverts it into the internal `reset_n`. The design is held in reset for one debounce window at power-up.
- Every asynchronous input passes through a two-flop `ASYNC_REG` synchroniser.
- SW15 is debounced (2²⁰ cycles ≈ 10.5 ms at 100 MHz) and edge-detected, so one flip gives exactly one encryption.
- All LEDs are driven from registers.

### Pin map

| Signal | Board | Pin |
|---|---|---|
| `clk` | 100 MHz oscillator | W5 |
| `btn_reset` | BTNC | U18 |
| `start_sw` | SW15 | R2 |
| `sw[0..7]` | SW0 to SW7 | V17, V16, W16, W17, W15, V15, W14, W13 |
| `leds[0..7]` | LD0 to LD7 | U16, E19, U19, V19, W18, U15, U14, V14 |
| `done_led` | LD14 | P1 |
| `busy_led` | LD15 | L1 |

## Verification

The testbench is self-checking: it prints `TEST PASSED` or `TEST FAILED` with a count, and every expected value comes from an independent software AES (Python `cryptography` / OpenSSL), not from the design itself.

**Part A: board level, through the real top-level pins (`STATIC_KEY = 1`)**
- 0x55 gives `c985043655121fdf1f87fbce7c7ca451`, LEDs = 0x51.
- 0xA3 gives `04b78440a7e7406597beca0dab5af9c2`; 0x00 gives `7df76b0c1ab899b33e42f047b91b546f`; 0xFF gives `8af2860142f786f409307c1a3f7eaaac`.
- Reset pressed mid-encryption aborts cleanly: no `output_valid`, LEDs cleared, and the engine works again afterwards.
- Every block is checked for 10-cycle core latency and 12-cycle request-to-result latency.

**Part B: core level (`STATIC_KEY = 0`)**
- 32 vectors, each with a different key: FIPS-197 Appendix B and C.1, NIST SP 800-38A F.1.1 and 26 random vectors.
- Streamed back-to-back at one block per clock, then again with random idle cycles. Every ciphertext bit, the output order and the latency are checked.

**Result:** 175 / 175 checks passed in both Icarus Verilog 12 and Vivado 2025.1 xsim. The full log is in [`results/simulation_log.txt`](results/simulation_log.txt).

**Fault injection** (to prove the testbench catches real bugs). Each fault made the run fail:

| Injected fault | Errors reported |
|---|---|
| One wrong S-box entry (0x53 → 0xEE) | 36 |
| MixColumns not bypassed in round 10 | 74 |
| Wrong Rcon[9] | 74 |

## Implementation results

Vivado 2025.1, post-route, top level `PasswordManagerDemo`. Full reports: [`results/timing_summary.rpt`](results/timing_summary.rpt) and [`results/utilization.rpt`](results/utilization.rpt).

| Metric | Value |
|---|---|
| Clock constraint | 10 ns (100 MHz) |
| WNS (setup) | +3.998 ns, 0 failing of 1,186 endpoints |
| WHS (hold) | +0.039 ns, 0 failing |
| Estimated Fmax | ≈ 166 MHz |
| Critical path | plaintext register → round 1 S-box (LUT6) → LUT5 → round 1 state register; 2 logic levels, mostly routing (plaintext register fan-out 149) |
| Slice LUTs | 5,378 / 20,800 (25.86%) |
| Slice registers | 1,075 / 41,600 (2.58%) |
| F7 / F8 muxes | 2,064 / 1,005 |
| Slices | 1,473 / 8,150 (18.07%) |
| BRAM / DSP | 0 / 0 |
| Bonded IOB | 21 |

Only `ciphertext[7:0]` reaches the LEDs, so Vivado removes the logic that feeds only the other 120 output bits. This is why the utilisation is lower than a full 128-bit-output design would need, and why synthesis prints many "unused sequential element removed" warnings. The `check_timing` warnings about inputs and outputs without I/O delays are expected, since those ports are covered by `set_false_path`.

## How to build

### Simulation only (Icarus Verilog)

```bash
iverilog -g2012 -o tb.vvp rtl/*.v rtl/*.sv sim/tb_PasswordManagerDemo.sv
vvp tb.vvp
```

### Vivado (batch)

Run from this folder:

```bash
vivado -mode batch -source build_aes_basys3.tcl -tclargs sim       # behavioural simulation only
vivado -mode batch -source build_aes_basys3.tcl -tclargs build     # synthesis, implementation, bitstream
vivado -mode batch -source build_aes_basys3.tcl -tclargs all       # simulation, then build (default)
vivado -mode batch -source build_aes_basys3.tcl -tclargs program   # program the board over JTAG
```

The script creates `vivado_proj/aes128_basys3.xpr`, stops with an error if the simulation log has no `TEST PASSED` line, writes `.bit` and `.bin` files, prints WNS/WHS and saves timing, utilisation, DRC and methodology reports in `vivado_proj/reports/`. It sets the xsim run time to 20 µs, because Vivado's default of 1000 ns stops the test (which needs about 4.5 µs) before it finishes.

From the Vivado GUI instead: open the Tcl Console, `cd` into this folder and run `source build_aes_basys3.tcl`.

## On-board test procedure

**Setup:** JP1 on JTAG, USB cable in the PROG/UART port. Program `vivado_proj/aes128_basys3.runs/impl_1/PasswordManagerDemo.bit` from the Hardware Manager (or use the `program` mode above).

**For each test:**
1. Put SW15 down and press BTNC.
2. Set SW0 to SW7 (SW0 is the rightmost switch, bit 0).
3. Flip SW15 up. LD14 (done) should light.
4. Compare LD0 to LD7 with the table.

| Plaintext byte | Switches up | LEDs on | Expected byte |
|---|---|---|---|
| 0x55 | SW6, SW4, SW2, SW0 | LD6, LD4, LD0 | 0x51 |
| 0xA3 | SW7, SW5, SW1, SW0 | LD7, LD6, LD1 | 0xC2 |
| 0x00 | none | LD6, LD5, LD3, LD2, LD1, LD0 | 0x6F |
| 0xFF | all eight | LD7, LD5, LD3, LD2 | 0xAC |

**Expected behaviour (not bugs):**
- LD15 (busy) never visibly lights, because an encryption takes only 120 ns.
- The result appears about 10 ms after flipping SW15, because of the debounce window.
- If SW15 is already up after programming or reset, one encryption runs automatically.
