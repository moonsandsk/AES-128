# Pipelined AES-128 Encryption Engine on FPGA

A fully pipelined, synthesizable AES-128 encryption engine for the Digilent Basys 3 (Xilinx Artix-7, `xc7a35tcpg236-1`), built and verified in Vivado 2025.1.

**Authors:** Aditi Chandra and Akanksha Venkatesh
**Course:** Machine Intelligence for Chip Security and Hardware Trust, Department of ECE, PES University
**Guide:** Prof. Nirmala Devi M

## Results

| | |
|---|---|
| Architecture | 10-stage pipeline, one register stage per AES round |
| Clock | 100 MHz, **timing met** (WNS +3.998 ns, WHS +0.039 ns, 0 failing endpoints) |
| Estimated Fmax | ≈ 166 MHz |
| Throughput | one 128-bit block per clock, 12.8 Gbit/s at 100 MHz |
| Latency | 10 cycles in the core, 12 cycles request-to-result |
| Resources | 5,378 LUTs (25.9%), 1,075 registers (2.6%), 0 BRAM, 0 DSP |
| Verification | **175 / 175** self-checking tests passed in Vivado xsim and Icarus Verilog |

Post-route figures from Vivado 2025.1 for the top level `PasswordManagerDemo`; the full [timing](vivado-fpga/results/timing_summary.rpt) and [utilisation](vivado-fpga/results/utilization.rpt) reports are in the repository. Every expected value in the testbench comes from an independent software AES (FIPS-197, NIST SP 800-38A and random vectors), not from the design itself.

## How it works

You set a plaintext byte on switches SW0 to SW7 and flip SW15 up. The byte is replicated into a 128-bit block, encrypted with the fixed key `2b7e151628aed2a6abf7158809cf4f3c` (the FIPS-197 example key), and the low byte of the ciphertext appears on LEDs LD0 to LD7. LD14 lights when the result is ready.

```
PasswordManagerDemo            board I/O: synchronisers, debounce, edge detect, LED registers
└── PasswordManagerFPGA        handshake controller (input_valid, busy, output_valid, done)
    └── aes_encrypt_128_pipeline   10-stage pipelined core + key expansion
        └── aes_round_function     SubBytes, ShiftRows, MixColumns, AddRoundKey
            └── aes_sbox           S-box generated from its GF(2⁸) definition
```

- **One round per stage.** The longest combinational path is a single AES round, which is what lets the design close timing at 100 MHz.
- **Valid bit travels with the data,** so each ciphertext is flagged in exactly the cycle it leaves round 10.
- **`STATIC_KEY` parameter.** `1` (used on the board) folds the key schedule into constants; `0` runs a parallel key pipeline so every block can carry its own key.
- **Board-safe I/O.** Two-flop synchronisers on every input, ~10 ms debounce, rising-edge start, and the active-high BTNC converted to an internal active-low synchronous reset.

Architecture, pin map, verification details and the full implementation report are in [`vivado-fpga/README.md`](vivado-fpga/README.md).

## Repository structure

```
.
├── vivado-fpga/                 AES-128 engine (Vivado)
│   ├── build_aes_basys3.tcl     one-command flow: simulate, synthesise, implement, bitstream, program
│   ├── rtl/                     S-box, round function, pipelined core, controller, top level
│   ├── sim/                     self-checking testbench (175 checks)
│   ├── constraints/             Basys 3 pin map and 100 MHz clock
│   └── results/                 simulation log, Vivado timing and utilisation reports
└── python-vault/                software password vault (AES-256-GCM + PBKDF2)
```

## Build and run

**Vivado** (run from `vivado-fpga/`):

```bash
vivado -mode batch -source build_aes_basys3.tcl -tclargs all       # simulate, then synthesise, implement, write bitstream
vivado -mode batch -source build_aes_basys3.tcl -tclargs program   # program the Basys 3 over JTAG
```

The script stops if the simulation does not report `TEST PASSED`, prints WNS/WHS after implementation, and writes timing and utilisation reports to `vivado_proj/reports/`.

**Simulation only, without Vivado:**

```bash
cd vivado-fpga
iverilog -g2012 -o tb.vvp rtl/*.v rtl/*.sv sim/tb_PasswordManagerDemo.sv && vvp tb.vvp
```

**On the board:** put SW15 down and press BTNC, set the plaintext on SW0 to SW7, then flip SW15 up.

| Plaintext | Expected LEDs (LD7..LD0) |
|---|---|
| 0x55 | 0x51 |
| 0xA3 | 0xC2 |
| 0x00 | 0x6F |
| 0xFF | 0xAC |

## Python password vault

[`python-vault/`](python-vault/) is a command-line password manager that uses the same cryptography in software: PBKDF2-HMAC-SHA256 key derivation (600,000 iterations) and AES-256-GCM authenticated encryption, with a self-clearing clipboard, a CSPRNG password generator and a wrong-password attack demo. Its weakness, that the key lives in host memory, is the reason for moving AES into dedicated hardware.

```bash
cd python-vault
pip install -r requirements.txt
python main.py
```

## Future work
- A decryption path, and integration as an AXI peripheral for a MicroBlaze system.

## References

1. NIST, *FIPS-197: Advanced Encryption Standard (AES)*.
2. NIST, *SP 800-38A: Recommendation for Block Cipher Modes of Operation*.
3. Xilinx, *UG949: UltraFast Design Methodology Guide*.
