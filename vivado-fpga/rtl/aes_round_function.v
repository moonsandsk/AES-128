//==============================================================================
// File        : aes_round_function.v
// Description : One complete AES-128 encryption round, purely combinational:
//                   SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
//               MixColumns is bypassed when is_final_round = 1 (Round 10),
//               exactly as specified in FIPS-197 Section 5.1.
//
// State layout: FIPS-197 column-major byte order. state[127:120] is byte 0
//               (row 0, col 0), state[119:112] is byte 1 (row 1, col 0), ...,
//               state[7:0] is byte 15 (row 3, col 3). Byte n = row (n%4),
//               column (n/4).
//
// Target      : Xilinx Artix-7 (Basys 3), Vivado
//==============================================================================
`timescale 1ns / 1ps
`default_nettype none

module aes_round_function (
    input  wire [127:0] state_in,
    input  wire [127:0] round_key,
    input  wire         is_final_round,
    output wire [127:0] state_out
);

    //--------------------------------------------------------------------------
    // GF(2^8) helpers (AES polynomial x^8 + x^4 + x^3 + x + 1)
    //--------------------------------------------------------------------------
    function automatic [7:0] xtime;            // multiply by {02}
        input [7:0] b;
        begin
            xtime = {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
        end
    endfunction

    function automatic [31:0] mix_column;      // MixColumns on one 32-bit column
        input [31:0] col;                      // col = {s0, s1, s2, s3}
        reg   [7:0]  s0, s1, s2, s3;
        begin
            s0 = col[31:24];
            s1 = col[23:16];
            s2 = col[15:8];
            s3 = col[7:0];
            // {02}a ^ {03}b ^ c ^ d, with {03}b = {02}b ^ b
            mix_column[31:24] = xtime(s0) ^ (xtime(s1) ^ s1) ^ s2 ^ s3;
            mix_column[23:16] = s0 ^ xtime(s1) ^ (xtime(s2) ^ s2) ^ s3;
            mix_column[15:8]  = s0 ^ s1 ^ xtime(s2) ^ (xtime(s3) ^ s3);
            mix_column[7:0]   = (xtime(s0) ^ s0) ^ s1 ^ s2 ^ xtime(s3);
        end
    endfunction

    //--------------------------------------------------------------------------
    // Step 1: SubBytes - 16 parallel S-box LUTs
    //--------------------------------------------------------------------------
    wire [127:0] sub_bytes;

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_sbox
            aes_sbox u_sbox (
                .sbox_in  (state_in [127 - 8*i -: 8]),
                .sbox_out (sub_bytes[127 - 8*i -: 8])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Step 2: ShiftRows - pure wiring (zero logic)
    //   Row r is rotated left by r bytes: out[r][c] = in[r][(c + r) mod 4]
    //   Byte index n = r + 4c  =>  out byte (r + 4c) = in byte (r + 4((c+r)%4))
    //--------------------------------------------------------------------------
    wire [127:0] shift_rows;

    genvar r, c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_sr_col
            for (r = 0; r < 4; r = r + 1) begin : g_sr_row
                assign shift_rows[127 - 8*(r + 4*c) -: 8] =
                       sub_bytes [127 - 8*(r + 4*((c + r) % 4)) -: 8];
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Step 3: MixColumns (bypassed on the final round)
    //--------------------------------------------------------------------------
    wire [127:0] mix_columns;

    assign mix_columns = {
        mix_column(shift_rows[127:96]),
        mix_column(shift_rows[95:64]),
        mix_column(shift_rows[63:32]),
        mix_column(shift_rows[31:0])
    };

    wire [127:0] mixed_or_bypassed = is_final_round ? shift_rows : mix_columns;

    //--------------------------------------------------------------------------
    // Step 4: AddRoundKey
    //--------------------------------------------------------------------------
    assign state_out = mixed_or_bypassed ^ round_key;

endmodule

`default_nettype wire
