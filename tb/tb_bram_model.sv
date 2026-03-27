// tb_bram_model.sv — directed testbench for bram_model.sv

`timescale 1ns/1ps

module tb_bram_model;
    // Clock/reset
    logic clk;
    logic rst_n;

    // Port A
    logic        a_valid;
    logic        a_wr_en;
    logic [5:0]  a_addr;
    logic [15:0] a_wr_data;
    logic [15:0] a_rd_data;
    logic        a_rd_data_valid;

    // Port B
    logic        b_valid;
    logic [5:0]  b_addr;
    logic [1:0]  b_wr_byte_en;
    logic [15:0] b_wr_data;

    // DUT instaantiation
    bram_model #(
        .T           (logic [15:0]),
        .DEPTH       (64),
        .READ_LATENCY(2)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .a_valid         (a_valid),
        .a_wr_en         (a_wr_en),
        .a_addr          (a_addr),
        .a_wr_data       (a_wr_data),
        .a_rd_data       (a_rd_data),
        .a_rd_data_valid (a_rd_data_valid),
        .b_valid         (b_valid),
        .b_addr          (b_addr),
        .b_wr_byte_en    (b_wr_byte_en),
        .b_wr_data       (b_wr_data)
    );

    int cycle_cnt;

    // Clock generation: toggles every 5 time units
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        // Default reset and inputs
        rst_n = 0;
        a_valid = 0;
        a_wr_en = 0;
        a_addr = 0;
        a_wr_data = 0;
        b_valid = 0;
        b_addr = 0;
        b_wr_byte_en = 2'b00;
        b_wr_data = 0;

        // Apply mandatory reset for 2 cycles
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Scenario 1 — Basic Port A write and read
        // Write a location
        a_valid = 1;
        a_wr_en = 1;
        a_addr = 6'd0;
        a_wr_data = 16'hABCD;
        @(posedge clk);

        // Issue read request next cycle
        a_valid = 1;
        a_wr_en = 0;
        a_addr = 6'd0;
        a_wr_data = 0;

        cycle_cnt = 1; // count includes the request cycle
        @(posedge clk);
        a_valid = 0;
        a_wr_en = 0;

        while (!a_rd_data_valid) begin
            cycle_cnt += 1;
            @(posedge clk);
        end

        assert (cycle_cnt == 2) else $fatal(1, "FAIL: Scenario 1 latency mismatch (got %0d, expected 2)", cycle_cnt);
        assert (a_rd_data == 16'hABCD) else $fatal(1, "FAIL: Scenario 1 read data mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 1 — Basic Port A write and read");

        // Scenario 2 — Multiple sequential Port A reads
        // Write sequence via Port A
        a_valid = 1; a_wr_en = 1; a_addr = 6'd0; a_wr_data = 16'h0001; @(posedge clk);
        a_valid = 1; a_wr_en = 1; a_addr = 6'd1; a_wr_data = 16'h0002; @(posedge clk);
        a_valid = 1; a_wr_en = 1; a_addr = 6'd2; a_wr_data = 16'h0003; @(posedge clk);
        a_valid = 1; a_wr_en = 1; a_addr = 6'd12; a_wr_data = 16'h0002; @(posedge clk); // for scenario 9

        // Read addr0
        a_valid = 1; a_wr_en = 0; a_addr = 6'd0; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h0001) else $fatal(1, "FAIL: Scenario 2 addr0 mismatch");

        // Read addr1
        a_valid = 1; a_wr_en = 0; a_addr = 6'd1; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h0002) else $fatal(1, "FAIL: Scenario 2 addr1 mismatch");

        // Read addr2
        a_valid = 1; a_wr_en = 0; a_addr = 6'd2; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h0003) else $fatal(1, "FAIL: Scenario 2 addr2 mismatch");

        $display("PASS: Scenario 2 — Multiple sequential Port A reads");

        // Scenario 3 — Port A read after write to same address
        a_valid = 1; a_wr_en = 1; a_addr = 6'd4; a_wr_data = 16'hDEAD; @(posedge clk);

        a_valid = 1; a_wr_en = 0; a_addr = 6'd4; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'hDEAD) else $fatal(1, "FAIL: Scenario 3 mismatch");
        $display("PASS: Scenario 3 — Port A read after write to same address");

        // Scenario 4 — Port B byte-enable write low byte only
        a_valid = 1; a_wr_en = 1; a_addr = 6'd5; a_wr_data = 16'hFFFF; @(posedge clk);

        b_valid = 1; b_addr = 6'd5; b_wr_byte_en = 2'b01; b_wr_data = 16'h00AB;
        a_valid = 0; a_wr_en = 0;
        @(posedge clk);
        b_valid = 0; b_wr_byte_en = 2'b00;

        a_valid = 1; a_wr_en = 0; a_addr = 6'd5; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'hFFAB) else $fatal(1, "FAIL: Scenario 4 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 4 — Port B byte-enable write low byte only");

        // Scenario 5 — Port B byte-enable write high byte only
        a_valid = 1; a_wr_en = 1; a_addr = 6'd6; a_wr_data = 16'hFFFF; @(posedge clk);
        a_valid = 0;
        b_valid = 1; b_addr = 6'd6; b_wr_byte_en = 2'b10; b_wr_data = 16'hCD00;
        @(posedge clk);
        b_valid = 0; b_wr_byte_en = 2'b00;

        a_valid = 1; a_wr_en = 0; a_addr = 6'd6; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'hCDFF) else $fatal(1, "FAIL: Scenario 5 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 5 — Port B byte-enable write high byte only");

        // Scenario 6 — Port B full write via all bytes enabled
        a_valid = 1; a_wr_en = 1; a_addr = 6'd7; a_wr_data = 16'hFFFF; @(posedge clk);
        a_valid = 0;
        b_valid = 1; b_addr = 6'd7; b_wr_byte_en = 2'b11; b_wr_data = 16'h1234;
        @(posedge clk);
        b_valid = 0; b_wr_byte_en = 2'b00;

        a_valid = 1; a_wr_en = 0; a_addr = 6'd7; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h1234) else $fatal(1, "FAIL: Scenario 6 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 6 — Port B full write via all bytes enabled");

        // Scenario 7 — Port A and Port B simultaneous write to same address — Port A wins
        a_valid = 1; a_wr_en = 1; a_addr = 6'd8; a_wr_data = 16'h1111;
        b_valid = 1; b_addr = 6'd8; b_wr_byte_en = 2'b11; b_wr_data = 16'h2222;
        @(posedge clk);
        a_valid = 0; a_wr_en = 0;
        b_valid = 0; b_wr_byte_en = 2'b00;

        a_valid = 1; a_wr_en = 0; a_addr = 6'd8; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h1111) else $fatal(1, "FAIL: Scenario 7 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 7 — Port A and Port B simultaneous write same address");

        // Scenario 8 — Port A and Port B simultaneous write to different addresses
        a_valid = 1; a_wr_en = 1; a_addr = 6'd9; a_wr_data = 16'hAAAA;
        b_valid = 1; b_addr = 6'd10; b_wr_byte_en = 2'b01; b_wr_data = 16'h00BB;
        @(posedge clk);
        a_valid = 0; a_wr_en = 0;
        b_valid = 0; b_wr_byte_en = 2'b00;

        // Read addr9
        a_valid = 1; a_wr_en = 0; a_addr = 6'd9; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'hAAAA) else $fatal(1, "FAIL: Scenario 8 addr9 mismatch (got %h)", a_rd_data);

        // Read addr10
        a_valid = 1; a_wr_en = 0; a_addr = 6'd10; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data[7:0] == 8'hBB) else $fatal(1, "FAIL: Scenario 8 addr10 low byte mismatch (got %h)", a_rd_data[7:0]);
        $display("PASS: Scenario 8 — Port A and Port B simultaneous writes to different addresses");

        // Scenario 9 — Port A write and read to different addresses simultaneously
        // Create a read request for addr12 (pre-written with 16'h0002) and, in flight, write addr11
        a_valid = 1; a_wr_en = 0; a_addr = 6'd12; @(posedge clk);

        a_valid = 1; a_wr_en = 1; a_addr = 6'd11; a_wr_data = 16'h5555; @(posedge clk);
        a_valid = 0; a_wr_en = 0;

        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h0002) else $fatal(1, "FAIL: Scenario 9 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 9 — Port A write and read to different addresses simultaneously");

        // Scenario 10 — Reset behavior
        a_valid = 1; a_wr_en = 1; a_addr = 6'd3; a_wr_data = 16'h1234; @(posedge clk);
        a_valid = 0; a_wr_en = 0;

        rst_n = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        a_valid = 1; a_wr_en = 0; a_addr = 6'd3; @(posedge clk); a_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert (a_rd_data == 16'h1234) else $fatal(1, "FAIL: Scenario 10 mismatch (got %h)", a_rd_data);
        $display("PASS: Scenario 10 — Reset behavior");

        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
