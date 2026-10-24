//==============================================================================
// File        : PasswordManagerFPGA.sv
// Description : Handshake / FSM controller wrapped around the 10-stage
//               pipelined AES-128 core.
//
//   Handshake (all signals synchronous to clk):
//     input_valid  : 1-cycle request; plaintext is sampled on this edge.
//                    Accepted only when busy = 0 (ignored while busy).
//     busy         : high from the cycle after acceptance until the
//                    ciphertext has been delivered.
//     output_valid : 1-cycle pulse, asserted in exactly the cycle that
//                    `ciphertext` first presents the new result. It is derived
//                    from the core's valid token, which travels through the
//                    same 10 pipeline stages as the data, so it can never
//                    drift from the data it qualifies.
//     done         : level, high from output_valid until the next request.
//     ciphertext   : held stable until the next result is delivered.
//
//   Timing (request accepted on edge T):
//     T+1  : plaintext register + core in_valid
//     T+11 : core out_valid (ciphertext leaves Round 10 register)
//     T+12 : ciphertext register updated, output_valid = 1, done = 1
//
//   pipe_stage reports which round register currently holds the block
//   (1..10), useful for an ILA or debug LEDs.
//
// Target      : Xilinx Artix-7 (Basys 3), Vivado
//==============================================================================
`timescale 1ns / 1ps
`default_nettype none

module PasswordManagerFPGA #(
    parameter logic [127:0] MASTER_KEY = 128'h2b7e151628aed2a6abf7158809cf4f3c
) (
    input  wire logic         clk,
    input  wire logic         reset_n,       // active-low synchronous reset
    input  wire logic         input_valid,
    input  wire logic [127:0] plaintext,
    output      logic         busy,
    output      logic         output_valid,
    output      logic         done,
    output      logic [127:0] ciphertext,
    output      logic [3:0]   pipe_stage
);

    localparam int unsigned PIPE_LATENCY = 10;

    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,   // waiting for first request
        S_ISSUE = 2'd1,   // block presented to core this cycle
        S_WAIT  = 2'd2,   // block travelling through rounds 1..10
        S_DONE  = 2'd3    // result held, ready for next request
    } state_t;

    state_t        state_q;
    logic [127:0]  pt_q;
    logic          core_in_valid;
    logic          core_out_valid;
    logic [127:0]  core_ciphertext;
    logic [3:0]    stage_cnt_q;

    //--------------------------------------------------------------------------
    // Pipelined AES-128 core
    //--------------------------------------------------------------------------
    aes_encrypt_128_pipeline #(
        .STATIC_KEY (1)                 // fixed master key -> constant-folded schedule
    ) u_aes_core (
        .clk        (clk),
        .reset_n    (reset_n),
        .in_valid   (core_in_valid),
        .plaintext  (pt_q),
        .key        (MASTER_KEY),
        .out_valid  (core_out_valid),
        .ciphertext (core_ciphertext)
    );

    assign core_in_valid = (state_q == S_ISSUE);

    //--------------------------------------------------------------------------
    // Plaintext input register (no reset needed: qualified by state)
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if ((state_q == S_IDLE || state_q == S_DONE) && input_valid)
            pt_q <= plaintext;
    end

    //--------------------------------------------------------------------------
    // Control FSM
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            state_q      <= S_IDLE;
            stage_cnt_q  <= '0;
            output_valid <= 1'b0;
        end else begin
            output_valid <= 1'b0;   // default: single-cycle pulse

            unique case (state_q)
                S_IDLE, S_DONE: begin
                    if (input_valid) begin
                        state_q     <= S_ISSUE;
                        stage_cnt_q <= '0;
                    end
                end

                S_ISSUE: begin
                    state_q     <= S_WAIT;
                    stage_cnt_q <= 4'd1;            // block now in Round 1 register
                end

                S_WAIT: begin
                    if (core_out_valid) begin       // block leaving Round 10 register
                        state_q      <= S_DONE;
                        output_valid <= 1'b1;
                        stage_cnt_q  <= '0;
                    end else if (stage_cnt_q < PIPE_LATENCY[3:0]) begin
                        stage_cnt_q <= stage_cnt_q + 4'd1;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Result register: captured in the exact cycle the core's valid token
    // emerges, so ciphertext and output_valid change on the same edge.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n)
            ciphertext <= '0;
        else if (state_q == S_WAIT && core_out_valid)
            ciphertext <= core_ciphertext;
    end

    assign busy       = (state_q == S_ISSUE) || (state_q == S_WAIT);
    assign done       = (state_q == S_DONE);
    assign pipe_stage = stage_cnt_q;

    //--------------------------------------------------------------------------
    // Simulation-only self-check: the valid token must emerge after exactly
    // PIPE_LATENCY cycles. Ignored by synthesis.
    //--------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (reset_n && state_q == S_WAIT && core_out_valid && stage_cnt_q != PIPE_LATENCY[3:0])
            $error("PasswordManagerFPGA: core latency mismatch (stage_cnt=%0d, expected %0d)",
                   stage_cnt_q, PIPE_LATENCY);
    end
    // synthesis translate_on

endmodule

`default_nettype wire
