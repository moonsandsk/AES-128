//==============================================================================
// File        : PasswordManagerDemo.sv
// Description : Basys 3 top level for the pipelined AES-128 engine.
//
//   Board I/O:
//     clk        W5   100 MHz oscillator
//     btn_reset  U18  BTNC. The Basys 3 pushbuttons are ACTIVE-HIGH (pressed
//                     = 1), so the raw pin is synchronised here and inverted
//                     into the internal active-low synchronous `reset_n`
//                     used by the whole design. Wiring an active-low port
//                     straight to U18 would hold the design in reset
//                     whenever the button is released.
//     start_sw   R2   SW15. Encryption fires on its rising edge (works for a
//                     slide switch or a pushbutton: debounced + edge-detected).
//     sw[7:0]    SW0-SW7  plaintext byte, replicated 16x into a 128-bit block.
//     leds[7:0]  LD0-LD7  ciphertext[7:0] (LSB of the result).
//     busy_led   LD15     encryption in flight.
//     done_led   LD14     ciphertext ready.
//
//   All asynchronous inputs pass through 2-flop synchronisers (ASYNC_REG) to
//   avoid metastability; start_sw and btn_reset are additionally debounced.
//
// Target      : Xilinx Artix-7 XC7A35T-1CPG236C (Basys 3), Vivado
//==============================================================================
`timescale 1ns / 1ps
`default_nettype none

module PasswordManagerDemo #(
    // 2^20 cycles @ 100 MHz = 10.5 ms debounce window. Override to a small
    // value in simulation.
    parameter int unsigned DEBOUNCE_BITS = 20
) (
    input  wire logic       clk,
    input  wire logic       btn_reset,   // BTNC, active-high on the board
    input  wire logic [7:0] sw,
    input  wire logic       start_sw,
    output      logic [7:0] leds,
    output      logic       busy_led,
    output      logic       done_led
);

    //--------------------------------------------------------------------------
    // Input synchronisers
    //--------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_sync_q   = 2'b00;
    (* ASYNC_REG = "TRUE" *) logic [1:0] start_sync_q = 2'b00;
    (* ASYNC_REG = "TRUE" *) logic [7:0] sw_meta_q    = '0;
    (* ASYNC_REG = "TRUE" *) logic [7:0] sw_sync_q    = '0;

    always_ff @(posedge clk) begin
        rst_sync_q   <= {rst_sync_q[0],   btn_reset};
        start_sync_q <= {start_sync_q[0], start_sw};
        sw_meta_q    <= sw;
        sw_sync_q    <= sw_meta_q;
    end

    //--------------------------------------------------------------------------
    // Debouncers: output follows input only after it has been stable for
    // 2^DEBOUNCE_BITS consecutive cycles.
    //--------------------------------------------------------------------------
    logic                     rst_db_q   = 1'b1;   // power up in reset
    logic [DEBOUNCE_BITS-1:0] rst_cnt_q  = '0;
    logic                     start_db_q = 1'b0;
    logic [DEBOUNCE_BITS-1:0] start_cnt_q = '0;

    always_ff @(posedge clk) begin
        if (rst_sync_q[1] == rst_db_q) begin
            rst_cnt_q <= '0;
        end else begin
            rst_cnt_q <= rst_cnt_q + 1'b1;
            if (&rst_cnt_q) rst_db_q <= rst_sync_q[1];
        end
    end

    // Internal active-low synchronous reset. Asserts immediately when the
    // button press passes the synchroniser OR while the debounced level is
    // high; it is held for at least one debounce window at power-up.
    logic reset_n;
    assign reset_n = ~(rst_db_q | rst_sync_q[1]);

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            start_db_q  <= 1'b0;
            start_cnt_q <= '0;
        end else if (start_sync_q[1] == start_db_q) begin
            start_cnt_q <= '0;
        end else begin
            start_cnt_q <= start_cnt_q + 1'b1;
            if (&start_cnt_q) start_db_q <= start_sync_q[1];
        end
    end

    //--------------------------------------------------------------------------
    // Rising-edge detect on start -> single-cycle request.
    // Plaintext is latched on the same edge: {16{sw}} = 128-bit block.
    //--------------------------------------------------------------------------
    logic         start_db_d_q;
    logic         input_valid_q;
    logic [127:0] plaintext_q;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            start_db_d_q  <= 1'b0;
            input_valid_q <= 1'b0;
        end else begin
            start_db_d_q  <= start_db_q;
            input_valid_q <= start_db_q & ~start_db_d_q;
        end
    end

    always_ff @(posedge clk) begin
        if (start_db_q & ~start_db_d_q)
            plaintext_q <= {16{sw_sync_q}};
    end

    //--------------------------------------------------------------------------
    // FSM controller + pipelined AES-128 core
    //--------------------------------------------------------------------------
    logic         busy;
    logic         output_valid;
    logic         done;
    logic [127:0] ciphertext;
    logic [3:0]   pipe_stage;

    PasswordManagerFPGA #(
        .MASTER_KEY (128'h2b7e151628aed2a6abf7158809cf4f3c)
    ) u_controller (
        .clk          (clk),
        .reset_n      (reset_n),
        .input_valid  (input_valid_q),
        .plaintext    (plaintext_q),
        .busy         (busy),
        .output_valid (output_valid),
        .done         (done),
        .ciphertext   (ciphertext),
        .pipe_stage   (pipe_stage)
    );

    //--------------------------------------------------------------------------
    // Registered LED drivers (keeps output paths short and glitch-free)
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            leds     <= '0;
            busy_led <= 1'b0;
            done_led <= 1'b0;
        end else begin
            leds     <= ciphertext[7:0];
            busy_led <= busy;
            done_led <= done;
        end
    end

endmodule

`default_nettype wire
