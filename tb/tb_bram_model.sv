// tb_bram_model.sv — directed testbench for bram_model.sv

`timescale 1ns/1ps

module tb_bram_model;

    // Clock and reset
    logic clk;
    logic rst_n;

    // Port A
    logic        a_wr_valid;
    logic [5:0]  a_wr_addr;
    logic [15:0] a_wr_data;

    logic        a_rd_valid;
    logic [5:0]  a_rd_addr;
    logic [15:0] a_rd_data;
    logic        a_rd_data_valid;
    logic        a_busy;

    // Port B
    logic        b_wr_valid;
    logic [5:0]  b_wr_addr;
    logic [1:0]  b_wr_byte_en;
    logic [15:0] b_wr_data;

    bram_model #(
        .T           (logic [15:0]),
        .DEPTH       (64),
        .READ_LATENCY(2)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .a_wr_valid     (a_wr_valid),
        .a_wr_addr      (a_wr_addr),
        .a_wr_data      (a_wr_data),
        .a_rd_valid     (a_rd_valid),
        .a_rd_addr      (a_rd_addr),
        .a_rd_data      (a_rd_data),
        .a_rd_data_valid(a_rd_data_valid),
        .a_busy         (a_busy),
        .b_wr_valid     (b_wr_valid),
        .b_wr_addr      (b_wr_addr),
        .b_wr_byte_en   (b_wr_byte_en),
        .b_wr_data      (b_wr_data)
    );

    int cycle_count;
    int got_pulses;
    logic [15:0] got_data;

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        // Defaults
        rst_n = 0;
        a_wr_valid = 0;
        a_wr_addr = 0;
        a_wr_data = 0;
        a_rd_valid = 0;
        a_rd_addr = 0;
        b_wr_valid = 0;
        b_wr_addr = 0;
        b_wr_byte_en = 0;
        b_wr_data = 0;

        // Reset sequence: low for 2 clock cycles
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Scenario 1 — Basic Port A write and read
        a_wr_valid = 1;
        a_wr_addr  = 6'd0;
        a_wr_data  = 16'hABCD;
        @(posedge clk);
        a_wr_valid = 0;

        @(posedge clk);
        a_rd_valid = 1;
        a_rd_addr  = 6'd0;

        cycle_count = 1; // including the read-request cycle
        @(posedge clk);
        a_rd_valid = 0;

        while (!a_rd_data_valid) begin
            cycle_count++;
            @(posedge clk);
        end

        assert(cycle_count == 2) else $fatal(1, "FAIL: Scenario 1 latency expected 2 got %0d", cycle_count);
        assert(a_rd_data == 16'hABCD) else $fatal(1, "FAIL: Scenario 1 data mismatch");
        assert(a_busy == 0) else $fatal(1, "FAIL: Scenario 1 a_busy should be low on data valid");
        $display("PASS: Scenario 1");

        // Scenario 2 — Multiple sequential Port A reads
        // Write three words into memory
        a_wr_valid = 1; a_wr_addr = 6'd0; a_wr_data = 16'h0001; @(posedge clk); a_wr_valid = 0;
        a_wr_valid = 1; a_wr_addr = 6'd1; a_wr_data = 16'h0002; @(posedge clk); a_wr_valid = 0;
        a_wr_valid = 1; a_wr_addr = 6'd2; a_wr_data = 16'h0003; @(posedge clk); a_wr_valid = 0;

        // Read 0
        a_rd_valid = 1; a_rd_addr = 6'd0; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'h0001) else $fatal(1, "FAIL: Scenario 2 read 0 value mismatch");

        // Read 1
        a_rd_valid = 1; a_rd_addr = 6'd1; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'h0002) else $fatal(1, "FAIL: Scenario 2 read 1 value mismatch");

        // Read 2
        a_rd_valid = 1; a_rd_addr = 6'd2; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'h0003) else $fatal(1, "FAIL: Scenario 2 read 2 value mismatch");

        $display("PASS: Scenario 2");

        // Scenario 3 — Port A busy blocking
        got_pulses = 0;
        got_data = 0;

        a_rd_valid = 1; a_rd_addr = 6'd0; @(posedge clk); a_rd_valid = 0;

        // Issue a second read while busy
        assert(a_busy == 1) else $fatal(1, "FAIL: Scenario 3 expected a_busy high");
        a_rd_valid = 1; a_rd_addr = 6'd1;
        @(posedge clk);
        a_rd_valid = 0;

        // Count data-valid pulses for a few cycles
        got_pulses = 0;
        for (int i = 0; i < 5; i++) begin
            if (a_rd_data_valid) begin
                got_pulses++;
                got_data = a_rd_data;
            end
            @(posedge clk);
        end

        assert(got_pulses == 1) else $fatal(1, "FAIL: Scenario 3 expected 1 pulse, got %0d", got_pulses);
        assert(got_data == 16'h0001) else $fatal(1, "FAIL: Scenario 3 data mismatch");
        $display("PASS: Scenario 3");

        // Scenario 4 — Port B byte-enable write low byte only
        a_wr_valid = 1; a_wr_addr = 6'd5; a_wr_data = 16'hFFFF; @(posedge clk); a_wr_valid = 0;
        @(posedge clk);
        b_wr_valid = 1; b_wr_addr = 6'd5; b_wr_byte_en = 2'b01; b_wr_data = 16'h00AB;
        @(posedge clk);
        b_wr_valid = 0; b_wr_byte_en = 0;

        a_rd_valid = 1; a_rd_addr = 6'd5; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'hFFAB) else $fatal(1, "FAIL: Scenario 4 expected 0xFFAB got %h", a_rd_data);
        $display("PASS: Scenario 4");

        // Scenario 5 — Port B byte-enable write high byte only
        a_wr_valid = 1; a_wr_addr = 6'd6; a_wr_data = 16'hFFFF; @(posedge clk); a_wr_valid = 0;
        @(posedge clk);
        b_wr_valid = 1; b_wr_addr = 6'd6; b_wr_byte_en = 2'b10; b_wr_data = 16'hCD00;
        @(posedge clk);
        b_wr_valid = 0; b_wr_byte_en = 0;

        a_rd_valid = 1; a_rd_addr = 6'd6; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'hCDFF) else $fatal(1, "FAIL: Scenario 5 expected 0xCDFF got %h", a_rd_data);
        $display("PASS: Scenario 5");

        // Scenario 6 — Port A and Port B simultaneous write same address Port A wins
        a_wr_valid = 1; a_wr_addr = 6'd7; a_wr_data = 16'h1111;
        b_wr_valid = 1; b_wr_addr = 6'd7; b_wr_byte_en = 2'b11; b_wr_data = 16'h2222;
        @(posedge clk);
        a_wr_valid = 0; b_wr_valid = 0; b_wr_byte_en = 0;

        a_rd_valid = 1; a_rd_addr = 6'd7; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'h1111) else $fatal(1, "FAIL: Scenario 6 expected 0x1111 got %h", a_rd_data);
        $display("PASS: Scenario 6");

        // Scenario 7 — Port A and Port B simultaneous write different addresses
        a_wr_valid = 1; a_wr_addr = 6'd8; a_wr_data = 16'hAAAA;
        b_wr_valid = 1; b_wr_addr = 6'd9; b_wr_byte_en = 2'b01; b_wr_data = 16'h00BB;
        @(posedge clk);
        a_wr_valid = 0; b_wr_valid = 0; b_wr_byte_en = 0;

        a_rd_valid = 1; a_rd_addr = 6'd8; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'hAAAA) else $fatal(1, "FAIL: Scenario 7 addr8 expected 0xAAAA got %h", a_rd_data);

        a_rd_valid = 1; a_rd_addr = 6'd9; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data[7:0] == 8'hBB) else $fatal(1, "FAIL: Scenario 7 addr9 expected low byte 0xBB got %02h", a_rd_data[7:0]);
        $display("PASS: Scenario 7");

        // Scenario 8 — Back-to-back Port A reads
        a_rd_valid = 1; a_rd_addr = 6'd0; @(posedge clk); a_rd_valid = 0;
        while (a_busy) @(posedge clk);
        
        // First result (addr0)
        assert(a_rd_data_valid == 1) else $fatal(1, "FAIL: Scenario 8 expected first data valid after busy deassertion");
        assert(a_rd_data == 16'h0001) else $fatal(1, "FAIL: Scenario 8 first read mismatch got %h", a_rd_data);
        
        // On cycle busy goes low, issue second read
        a_rd_valid = 1; a_rd_addr = 6'd1; @(posedge clk); a_rd_valid = 0;
        while (a_busy) @(posedge clk);

        // Second result (addr1)
        assert(a_rd_data_valid == 1) else $fatal(1, "FAIL: Scenario 8 expected second data valid after busy deassertion");
        assert(a_rd_data == 16'h0002) else $fatal(1, "FAIL: Scenario 8 second read mismatch got %h", a_rd_data);
        $display("PASS: Scenario 8");

        // Scenario 9 — Reset behavior
        a_wr_valid = 1; a_wr_addr = 6'd3; a_wr_data = 16'h1234; @(posedge clk); a_wr_valid = 0;

        rst_n = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        assert(a_busy == 0) else $fatal(1, "FAIL: Scenario 9 a_busy must be low after reset");

        a_rd_valid = 1; a_rd_addr = 6'd3; @(posedge clk); a_rd_valid = 0;
        while (!a_rd_data_valid) @(posedge clk);
        assert(a_rd_data == 16'h1234) else $fatal(1, "FAIL: Scenario 9 memory not retained after reset; got %h", a_rd_data);
        $display("PASS: Scenario 9");

        $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
