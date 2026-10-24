//==============================================================================
// File        : aes_encrypt_128_pipeline.v
// Description : Fully pipelined AES-128 encryption core.
//
//   * Exactly 10 pipeline stages, one per AES round. Every stage owns a
//     128-bit state register that latches on the rising clock edge.
//   * Key schedule (selected by STATIC_KEY):
//       STATIC_KEY = 0: computed on the fly in a parallel 10-stage key
//         pipeline, so each block travels with its own round key and the
//         key may change on every clock cycle.
//       STATIC_KEY = 1: for a fixed key (as in the Basys 3 demo). The round
//         keys are constant-folded at synthesis, leaving only the data
//         pipeline (saves ~1,150 FFs and 40 S-boxes).
//   * A 10-bit valid shift register travels alongside the data, so out_valid
//     asserts exactly in the cycle the matching ciphertext leaves stage 10.
//   * Throughput: one 128-bit block per clock (12.8 Gbit/s at 100 MHz).
//     Latency : 10 clock cycles from in_valid to out_valid.
//
//   Stage 1 combinationally performs the initial AddRoundKey (pt ^ K0) in
//   front of Round 1, so there are exactly 10 register stages. Inputs should
//   come straight from flip-flops (the FSM controller guarantees this).
//
//   Datapath registers deliberately have no reset (Xilinx UG949 practice):
//   only the valid bits are reset, which is all that's needed for correct
//   handshaking and it keeps the wide registers free of reset fan-out.
//
// Target      : Xilinx Artix-7 (Basys 3), Vivado
//==============================================================================
`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// One step of the AES-128 key expansion (FIPS-197 Section 5.2):
// derives round key i from round key i-1.
//------------------------------------------------------------------------------
module aes_key_expand_step (
    input  wire [127:0] key_in,
    input  wire [7:0]   rcon,
    output wire [127:0] key_out
);

    wire [31:0] w0 = key_in[127:96];
    wire [31:0] w1 = key_in[95:64];
    wire [31:0] w2 = key_in[63:32];
    wire [31:0] w3 = key_in[31:0];

    // RotWord: {a0,a1,a2,a3} -> {a1,a2,a3,a0}
    wire [31:0] rot_w3 = {w3[23:0], w3[31:24]};

    // SubWord: 4 S-boxes
    wire [31:0] sub_w3;
    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : g_ks_sbox
            aes_sbox u_sbox (
                .sbox_in  (rot_w3[31 - 8*b -: 8]),
                .sbox_out (sub_w3[31 - 8*b -: 8])
            );
        end
    endgenerate

    wire [31:0] w4 = w0 ^ sub_w3 ^ {rcon, 24'h000000};
    wire [31:0] w5 = w1 ^ w4;
    wire [31:0] w6 = w2 ^ w5;
    wire [31:0] w7 = w3 ^ w6;

    assign key_out = {w4, w5, w6, w7};

endmodule


//------------------------------------------------------------------------------
// 10-stage pipelined AES-128 encryption core
//------------------------------------------------------------------------------
module aes_encrypt_128_pipeline #(
    // 0 : per-block key. The key schedule runs in its own 10-stage pipeline
    //     beside the data, so `key` may change every cycle (sampled with
    //     in_valid together with the plaintext).
    // 1 : static key. `key` must be a constant tie-off (or a quasi-static
    //     value changed only while the pipeline is empty). Round keys are
    //     derived combinationally from `key`; with a constant key, synthesis
    //     reduces the entire key schedule to constants (0 LUTs, 0 FFs).
    parameter integer STATIC_KEY = 0
) (
    input  wire         clk,
    input  wire         reset_n,      // active-low synchronous reset (valid bits only)
    input  wire         in_valid,     // plaintext/key accepted on this cycle
    input  wire [127:0] plaintext,
    input  wire [127:0] key,          // cipher key K0
    output wire         out_valid,    // ciphertext valid this cycle
    output wire [127:0] ciphertext
);

    localparam integer NUM_ROUNDS = 10;

    // Round constants Rcon[1..10] (FIPS-197 Section 5.2)
    function automatic [7:0] rcon_of;
        input integer round;
        begin
            case (round)
                1:       rcon_of = 8'h01;
                2:       rcon_of = 8'h02;
                3:       rcon_of = 8'h04;
                4:       rcon_of = 8'h08;
                5:       rcon_of = 8'h10;
                6:       rcon_of = 8'h20;
                7:       rcon_of = 8'h40;
                8:       rcon_of = 8'h80;
                9:       rcon_of = 8'h1b;
                10:      rcon_of = 8'h36;
                default: rcon_of = 8'h00;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Pipeline registers. Index 0 is the (unregistered) core input;
    // indices 1..10 are the 10 round registers.
    //--------------------------------------------------------------------------
    wire [127:0] stage_state [0:NUM_ROUNDS];
    wire [127:0] stage_key   [0:NUM_ROUNDS];
    wire         stage_valid [0:NUM_ROUNDS];
    wire [127:0] static_rk   [0:NUM_ROUNDS];   // static-key mode round keys

    // Initial AddRoundKey with the cipher key, folded into Stage 1
    assign stage_state[0] = plaintext ^ key;
    assign stage_key[0]   = key;
    assign stage_valid[0] = in_valid;
    assign static_rk[0]   = key;

    genvar s;
    generate
        for (s = 1; s <= NUM_ROUNDS; s = s + 1) begin : g_round
            wire [127:0] round_key;
            wire [127:0] round_out;

            // Round key s = KeyExpansion step applied to round key s-1.
            // Per-block mode: s-1 comes from the previous stage's key register.
            // Static mode   : s-1 comes from the previous combinational step.
            aes_key_expand_step u_key_step (
                .key_in  ((STATIC_KEY != 0) ? static_rk[s-1] : stage_key[s-1]),
                .rcon    (rcon_of(s)),
                .key_out (round_key)
            );
            assign static_rk[s] = round_key;

            aes_round_function u_round (
                .state_in       (stage_state[s-1]),
                .round_key      (round_key),
                .is_final_round ((s == NUM_ROUNDS) ? 1'b1 : 1'b0),
                .state_out      (round_out)
            );

            // 128-bit round state register (+ matching round-key register
            // in per-block mode; not needed after the last round)
            reg [127:0] state_q;
            reg         valid_q;

            always @(posedge clk) begin
                state_q <= round_out;
            end

            if (STATIC_KEY == 0 && s < NUM_ROUNDS) begin : g_key_reg
                reg [127:0] key_q;
                always @(posedge clk) key_q <= round_key;
                assign stage_key[s] = key_q;
            end else begin : g_no_key_reg
                assign stage_key[s] = 128'd0;
            end

            always @(posedge clk) begin
                if (!reset_n) valid_q <= 1'b0;
                else          valid_q <= stage_valid[s-1];
            end

            assign stage_state[s] = state_q;
            assign stage_valid[s] = valid_q;
        end
    endgenerate

    assign ciphertext = stage_state[NUM_ROUNDS];
    assign out_valid  = stage_valid[NUM_ROUNDS];

endmodule

`default_nettype wire
