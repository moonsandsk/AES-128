//==============================================================================
// File        : tb_PasswordManagerDemo.sv
// Description : Self-checking testbench for the Basys 3 AES-128 demo.
//
//   Part A - Board-level tests through PasswordManagerDemo (real pins):
//     A1. Reset, then sw = 0x55 -> plaintext 128'h5555...55.
//         Key 2b7e1516 28aed2a6 abf71588 09cf4f3c gives ciphertext
//         128'hc985043655121fdf1f87fbce7c7ca451, so the LED byte must be 0x51.
//     A2. Further bytes (0xA3, 0x00, 0xFF) re-using the engine.
//     A3. Reset pressed mid-encryption must abort cleanly (no result).
//     A4. Handshake timing: output_valid exactly 12 cycles after the request
//         (1 issue cycle + 10 round registers + 1 result register), and the
//         core's valid token leaves Round 10 exactly 10 cycles after issue.
//
//   Part B - Core-level stress of aes_encrypt_128_pipeline (STATIC_KEY = 0;
//            Part A covers STATIC_KEY = 1 through the controller):
//     32 vectors (FIPS-197 App. B & C.1, NIST SP 800-38A F.1.1, 26 random)
//     with a DIFFERENT key on each one, streamed back-to-back (1 block/clock)
//     and then again with random bubbles. Checks every ciphertext bit, order
//     and the 10-cycle latency.
//
//   Expected values were produced by an independent software AES
//   implementation (Python `cryptography` / OpenSSL).
//
// Simulators   : Vivado xsim, Icarus Verilog 12 (iverilog -g2012)
//==============================================================================
`timescale 1ns / 1ps

module tb_PasswordManagerDemo;

    //--------------------------------------------------------------------------
    // Clock: 100 MHz (10 ns period)
    //--------------------------------------------------------------------------
    localparam real CLK_PERIOD = 10.0;
    logic clk = 1'b0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    integer cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    integer errors = 0;
    integer checks = 0;

    //==========================================================================
    // Part A: board-level DUT
    //==========================================================================
    logic       btn_reset = 1'b1;
    logic [7:0] sw        = 8'h00;
    logic       start_sw  = 1'b0;
    wire  [7:0] leds;
    wire        busy_led;
    wire        done_led;

    PasswordManagerDemo #(
        .DEBOUNCE_BITS (3)          // 8-cycle debounce for fast simulation
    ) dut (
        .clk       (clk),
        .btn_reset (btn_reset),
        .sw        (sw),
        .start_sw  (start_sw),
        .leds      (leds),
        .busy_led  (busy_led),
        .done_led  (done_led)
    );

    localparam logic [127:0] MASTER_KEY = 128'h2b7e151628aed2a6abf7158809cf4f3c;

    // Hierarchical probes for timing checks
    wire         ctl_input_valid  = dut.u_controller.input_valid;
    wire         ctl_output_valid = dut.u_controller.output_valid;
    wire [127:0] ctl_ciphertext   = dut.u_controller.ciphertext;
    wire         core_in_valid    = dut.u_controller.u_aes_core.in_valid;
    wire         core_out_valid   = dut.u_controller.u_aes_core.out_valid;
    wire         int_reset_n      = dut.reset_n;

    integer req_cycle   = -1;
    integer issue_cycle = -1;
    integer ov_count    = 0;

    always @(posedge clk) begin
        if (int_reset_n) begin
            if (ctl_input_valid && !dut.u_controller.busy) req_cycle <= cycle;
            if (core_in_valid) issue_cycle <= cycle;
            if (core_out_valid) begin
                checks = checks + 1;
                if (cycle - issue_cycle != 10) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: core latency %0d cycles, expected 10",
                             $time, cycle - issue_cycle);
                end
            end
            if (ctl_output_valid) begin
                ov_count = ov_count + 1;
                checks   = checks + 1;
                if (cycle - req_cycle != 12) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: output_valid %0d cycles after request, expected 12",
                             $time, cycle - req_cycle);
                end
            end
        end
    end

    task automatic check128(input string what, input logic [127:0] got, input logic [127:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[%0t] ERROR: %s = %032h, expected %032h", $time, what, got, exp);
        end else begin
            $display("[%0t] PASS : %s = %032h", $time, what, got);
        end
    endtask

    task automatic check8(input string what, input logic [7:0] got, input logic [7:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[%0t] ERROR: %s = 0x%02h, expected 0x%02h", $time, what, got, exp);
        end else begin
            $display("[%0t] PASS : %s = 0x%02h", $time, what, got);
        end
    endtask

    task automatic press_reset();
        btn_reset = 1'b1;
        repeat (20) @(posedge clk);
        btn_reset = 1'b0;
        wait (int_reset_n === 1'b1);
        repeat (2) @(posedge clk);
    endtask

    // Sets the switches, flips start_sw, waits for done_led and checks results.
    task automatic encrypt_on_board(input logic [7:0] pt_byte, input logic [127:0] exp_ct);
        integer timeout;
        integer ov_before;
        logic   saw_busy;
        ov_before = ov_count;
        saw_busy  = 1'b0;
        @(negedge clk) sw = pt_byte;
        repeat (5) @(posedge clk);                 // let switches pass the synchroniser
        @(negedge clk) start_sw = 1'b1;
        timeout = 0;
        while (done_led !== 1'b1 || ov_count == ov_before) begin
            @(posedge clk);
            if (busy_led === 1'b1) saw_busy = 1'b1;
            timeout = timeout + 1;
            if (timeout > 200) begin
                errors = errors + 1;
                $display("[%0t] ERROR: timeout waiting for done_led (pt=0x%02h)", $time, pt_byte);
                disable encrypt_on_board;
            end
        end
        checks = checks + 1;
        if (!saw_busy) begin
            errors = errors + 1;
            $display("[%0t] ERROR: busy_led never asserted", $time);
        end
        @(posedge clk); #1;                        // LED registers are one cycle behind
        check128($sformatf("plaintext  (sw=0x%02h)", pt_byte), dut.u_controller.pt_q, {16{pt_byte}});
        check128($sformatf("ciphertext (sw=0x%02h)", pt_byte), ctl_ciphertext, exp_ct);
        check8  ($sformatf("leds       (sw=0x%02h)", pt_byte), leds, exp_ct[7:0]);
        check8  ("busy_led after done", {7'd0, busy_led}, 8'h00);
        check8  ("done_led after done", {7'd0, done_led}, 8'h01);
        @(negedge clk) start_sw = 1'b0;
        repeat (15) @(posedge clk);                // let debounced start fall
    endtask

    //==========================================================================
    // Part B: core-level DUT with independent stimulus
    //==========================================================================
    localparam int NVEC = 32;
    logic [127:0] vec_key [0:NVEC-1];
    logic [127:0] vec_pt  [0:NVEC-1];
    logic [127:0] vec_ct  [0:NVEC-1];

    logic         c_reset_n   = 1'b0;
    logic         c_in_valid  = 1'b0;
    logic [127:0] c_plaintext = '0;
    logic [127:0] c_key       = '0;
    wire          c_out_valid;
    wire  [127:0] c_ciphertext;

    aes_encrypt_128_pipeline #(
        .STATIC_KEY (0)                 // per-block key pipeline under test
    ) core_dut (
        .clk        (clk),
        .reset_n    (c_reset_n),
        .in_valid   (c_in_valid),
        .plaintext  (c_plaintext),
        .key        (c_key),
        .out_valid  (c_out_valid),
        .ciphertext (c_ciphertext)
    );

    integer c_issue_cycle [0:NVEC-1];
    integer c_issued   = 0;
    integer c_received = 0;

    always @(posedge clk) begin
        if (c_reset_n && c_in_valid) begin
            c_issue_cycle[c_issued % NVEC] <= cycle;
            c_issued <= c_issued + 1;
        end
        if (c_reset_n && c_out_valid) begin
            checks = checks + 2;
            if (c_ciphertext !== vec_ct[c_received % NVEC]) begin
                errors = errors + 1;
                $display("[%0t] ERROR: core vec %0d ct=%032h exp=%032h", $time,
                         c_received % NVEC, c_ciphertext, vec_ct[c_received % NVEC]);
            end
            if (cycle - c_issue_cycle[c_received % NVEC] != 10) begin
                errors = errors + 1;
                $display("[%0t] ERROR: core vec %0d latency %0d", $time,
                         c_received % NVEC, cycle - c_issue_cycle[c_received % NVEC]);
            end
            c_received <= c_received + 1;
        end
    end

    task automatic stream_vectors(input bit with_bubbles);
        integer i;
        i = 0;
        while (i < NVEC) begin
            @(negedge clk);
            if (with_bubbles && ($urandom % 3 == 0)) begin
                c_in_valid  = 1'b0;
                c_plaintext = {4{$urandom}};      // garbage on idle cycles
                c_key       = {4{$urandom}};
            end else begin
                c_in_valid  = 1'b1;
                c_plaintext = vec_pt[i];
                c_key       = vec_key[i];
                i = i + 1;
            end
        end
        @(negedge clk) c_in_valid = 1'b0;
    endtask

    //==========================================================================
    // Main sequence
    //==========================================================================
    initial begin
        vec_key[0] = 128'h2b7e151628aed2a6abf7158809cf4f3c; vec_pt[0] = 128'h3243f6a8885a308d313198a2e0370734; vec_ct[0] = 128'h3925841d02dc09fbdc118597196a0b32;
        vec_key[1] = 128'h000102030405060708090a0b0c0d0e0f; vec_pt[1] = 128'h00112233445566778899aabbccddeeff; vec_ct[1] = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
        vec_key[2] = 128'h2b7e151628aed2a6abf7158809cf4f3c; vec_pt[2] = 128'h6bc1bee22e409f96e93d7e117393172a; vec_ct[2] = 128'h3ad77bb40d7a3660a89ecaf32466ef97;
        vec_key[3] = 128'h2b7e151628aed2a6abf7158809cf4f3c; vec_pt[3] = 128'hae2d8a571e03ac9c9eb76fac45af8e51; vec_ct[3] = 128'hf5d3d58503b9699de785895a96fdbaaf;
        vec_key[4] = 128'h2b7e151628aed2a6abf7158809cf4f3c; vec_pt[4] = 128'h30c81c46a35ce411e5fbc1191a0a52ef; vec_ct[4] = 128'h43b1cd7f598ece23881b00e3ed030688;
        vec_key[5] = 128'h2b7e151628aed2a6abf7158809cf4f3c; vec_pt[5] = 128'hf69f2445df4f9b17ad2b417be66c3710; vec_ct[5] = 128'h7b0c785e27e8ad3f8223207104725dd4;
        vec_key[6] = 128'hf38b2ffc80a4df5a51c9bc701e7ea419; vec_pt[6] = 128'hf3f49249dc28ff90a5aec7978306d03b; vec_ct[6] = 128'h53f18f623547a3077b7df2c1653f4a5b;
        vec_key[7] = 128'he512148239292d22e255accb1a466884; vec_pt[7] = 128'h6bad6be28e7aa6e99f19950499dd251d; vec_ct[7] = 128'ha74693d19d41209a81ac81d23f28fde3;
        vec_key[8] = 128'hd7a7a3cc8c3d5f169293de8fc88b2875; vec_pt[8] = 128'h7dabe929c4a334bfc6cd75e9bb049a79; vec_ct[8] = 128'h53f4f835af884f59b610062f3e0c0909;
        vec_key[9] = 128'h70eb9a0a96263ae6c5e818fac0433cbd; vec_pt[9] = 128'h14aa4e719d3c7dec00a61f933d6c51e3; vec_ct[9] = 128'hc9446383ee2c4ee1f6c6ce5b67e2d344;
        vec_key[10] = 128'h1919e93ad11745ad498893101c593af5; vec_pt[10] = 128'he4163207d094499602f0ee99731c9452; vec_ct[10] = 128'h3e470edf353b1a690a1d8d4df7a328ae;
        vec_key[11] = 128'h5071950eadec6f117d836e77af67d461; vec_pt[11] = 128'h59001ac9406329bc65b00a2d35d14880; vec_ct[11] = 128'haca4df1fa7605dd89f9db378fe77e9b9;
        vec_key[12] = 128'h5b4c8012ede7bd0cffb88309fadb8908; vec_pt[12] = 128'hbef7e268ffe976ab60581ccace1d62e0; vec_ct[12] = 128'h18404f5bbc8921aa0cd4e82ba2dfd190;
        vec_key[13] = 128'hb91dddd91389b372a341738c837a7935; vec_pt[13] = 128'h89be9c1c8eb5140f16f4488157241955; vec_ct[13] = 128'h3190f4d5dc4d5685f51293db74c5f84a;
        vec_key[14] = 128'h24114258751b4c8349a047dc4ac87fc0; vec_pt[14] = 128'hb766ff10b437bdb5a51149bbe060a724; vec_ct[14] = 128'h7fb6d879fd7da9df86ba276086488eb1;
        vec_key[15] = 128'hd9090b89065550964f1a8a1d93d20470; vec_pt[15] = 128'h7608d9425d111a9d5e6c9992b5fb12e0; vec_ct[15] = 128'h83a73acae5faf820701e9c2856a1e3b6;
        vec_key[16] = 128'he41686cd66160227173714726c167229; vec_pt[16] = 128'hde0279e17f9ac0988df05f2595f19a51; vec_ct[16] = 128'he33b6dd41a40402967e91389f18a5f71;
        vec_key[17] = 128'hcd73de0081a0ba056ce9da661dcf884c; vec_pt[17] = 128'he01c683e99a46df0dde3a361c0099eba; vec_ct[17] = 128'hb17302bc35806098438ca51bf18ccf5b;
        vec_key[18] = 128'h864fa3f3eab06e9b65ed0de47db4304d; vec_pt[18] = 128'h90624fe36b82e6c9d82fb0f1423674a6; vec_ct[18] = 128'hfa71d19fa2ca44856dc0f0cec4cbdb63;
        vec_key[19] = 128'h8350a73f7aac319ffb759e0fed1d9d16; vec_pt[19] = 128'h93550840067f0cfcce1fd3d9849acfb5; vec_ct[19] = 128'h0930e022b5b51206c61195337a7d0beb;
        vec_key[20] = 128'hd1711cbd2106119ec40d31b5397a7623; vec_pt[20] = 128'h85f184e0b464c554f675299b0c83e786; vec_ct[20] = 128'h6c9322fee282128043ed6db48df9ed06;
        vec_key[21] = 128'hb7a1774f1a42721eaba4c70ee306f0c4; vec_pt[21] = 128'h2475263c785490146dedc86a9f4fb02b; vec_ct[21] = 128'he095417a24937a0d23d328817f5c07b0;
        vec_key[22] = 128'hd98145593a9afa39e261e34a7b6bc3c6; vec_pt[22] = 128'hb3618e1ca06d7a691f3c42b2e2cbbb93; vec_ct[22] = 128'h3927156c8a86876f8c5c1e7142cf7d5b;
        vec_key[23] = 128'hb6eafff5782afe6bac9f21df74f09af5; vec_pt[23] = 128'hfa97002cfcbad167f5a9ca5fedf165da; vec_ct[23] = 128'h35735df75ecf6ef96b33fa60756e412c;
        vec_key[24] = 128'h66eebc578f4ecb4f4041f5ee8bae8e66; vec_pt[24] = 128'h8c53765f4ec0a954ff8b2a6aab74fe57; vec_ct[24] = 128'h1d55078df546935793160dfe3eeef4d3;
        vec_key[25] = 128'hb2c55523807c7e30a598d0dbccbfd2ec; vec_pt[25] = 128'h66e61127e26b524ace0d8d877a98b9ac; vec_ct[25] = 128'h3995c4527eb142b72e38750256f6a43f;
        vec_key[26] = 128'hd4f398ee4b5c1a9533d918086edd77d8; vec_pt[26] = 128'h265c28ea0879d955025ff87c44df8a13; vec_ct[26] = 128'h13d2509f55360e4de4cf1cc9aae2ca94;
        vec_key[27] = 128'hf5ee8c7298e6e5b7e1cd7be8a7d83351; vec_pt[27] = 128'hed4d19b885dc0a68cdb54088754e64f4; vec_ct[27] = 128'ha0161dd5456b637d67c5d0965e3c8e69;
        vec_key[28] = 128'h33288e16ebe80fa95c24c1ae7d510557; vec_pt[28] = 128'h7776c6557c4e4248b1515fff42969a50; vec_ct[28] = 128'h36143269a8ee08df207bdc1a1072783b;
        vec_key[29] = 128'h7f45b096d3801b73c446ab8c82e26123; vec_pt[29] = 128'ha9f5307c8ece78b06f29a9f1ced66b44; vec_ct[29] = 128'hd11783cdc6c83044556308775e2d3d59;
        vec_key[30] = 128'h4a41f8e4d4d6d278089b5123e842997d; vec_pt[30] = 128'hcfd8c364eab42bd67528ea79511070a7; vec_ct[30] = 128'h791eb8249b31a1e341ba4e1f5b9d4193;
        vec_key[31] = 128'hb76dc0c3b07822db703e53cf192f09a9; vec_pt[31] = 128'h4242c22583e2665af6540600c8fb4456; vec_ct[31] = 128'hfd294493cc06dfa9de265a7b16235e63;

        $display("==============================================================");
        $display(" AES-128 pipelined engine - Basys 3 testbench");
        $display("==============================================================");

        //---------------- Part A ----------------
        press_reset();
        check8("leds after reset", leds, 8'h00);

        $display("--- A1: sw = 0x55 (plaintext 128'h5555...55) ---");
        encrypt_on_board(8'h55, 128'hc985043655121fdf1f87fbce7c7ca451);
        if (leds === 8'h51)
            $display("        LSB = 0x51 (note: 0x79 is NOT the AES-128 result for this key/plaintext)");

        $display("--- A2: additional plaintext bytes ---");
        encrypt_on_board(8'ha3, 128'h04b78440a7e7406597beca0dab5af9c2);
        encrypt_on_board(8'h00, 128'h7df76b0c1ab899b33e42f047b91b546f);
        encrypt_on_board(8'hff, 128'h8af2860142f786f409307c1a3f7eaaac);

        $display("--- A3: reset asserted mid-encryption ---");
        begin : a3
            integer ov_before;
            ov_before = ov_count;
            @(negedge clk) sw = 8'h3c;
            repeat (5) @(posedge clk);
            @(negedge clk) start_sw = 1'b1;
            wait (busy_led === 1'b1);
            repeat (3) @(posedge clk);
            @(negedge clk) start_sw = 1'b0;
            btn_reset = 1'b1;
            repeat (20) @(posedge clk);
            check8("busy_led during reset", {7'd0, busy_led}, 8'h00);
            check8("done_led during reset", {7'd0, done_led}, 8'h00);
            btn_reset = 1'b0;
            wait (int_reset_n === 1'b1);
            repeat (30) @(posedge clk);
            checks = checks + 1;
            if (ov_count != ov_before) begin
                errors = errors + 1;
                $display("[%0t] ERROR: aborted block produced output_valid", $time);
            end else
                $display("[%0t] PASS : aborted block produced no output", $time);
            check8("leds after abort", leds, 8'h00);
        end

        // Engine still works after abort
        encrypt_on_board(8'h55, 128'hc985043655121fdf1f87fbce7c7ca451);

        //---------------- Part B ----------------
        $display("--- B1: core streaming, 32 vectors back-to-back, per-block keys ---");
        repeat (3) @(posedge clk);
        @(negedge clk) c_reset_n = 1'b1;
        stream_vectors(1'b0);
        repeat (15) @(posedge clk);
        checks = checks + 1;
        if (c_received != NVEC) begin
            errors = errors + 1;
            $display("[%0t] ERROR: core produced %0d results, expected %0d", $time, c_received, NVEC);
        end else
            $display("[%0t] PASS : core produced %0d/%0d correct results at 1 block/clock", $time, c_received, NVEC);

        $display("--- B2: core streaming with random bubbles ---");
        stream_vectors(1'b1);
        repeat (15) @(posedge clk);
        checks = checks + 1;
        if (c_received != 2*NVEC) begin
            errors = errors + 1;
            $display("[%0t] ERROR: core produced %0d results, expected %0d", $time, c_received, 2*NVEC);
        end else
            $display("[%0t] PASS : core produced %0d/%0d correct results with bubbles", $time, c_received - NVEC, NVEC);

        //---------------- Summary ----------------
        $display("==============================================================");
        if (errors == 0)
            $display(" TEST PASSED : %0d checks, 0 errors", checks);
        else
            $display(" TEST FAILED : %0d checks, %0d errors", checks, errors);
        $display("==============================================================");
        $finish;
    end

    // Global watchdog
    initial begin
        #200000;
        $display("ERROR: global simulation timeout");
        $finish;
    end

endmodule
