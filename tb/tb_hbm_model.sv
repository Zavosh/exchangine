// tb_hbm_model.sv — directed testbench for updated three-port hbm_model.sv
`timescale 1ns/1ps

module tb_hbm_model;
    // Clock and reset
    logic clk;
    logic rst_n;

    // Port A burst read/write
    logic                a_wr_valid;
    logic [5:0]          a_wr_addr;
    logic [15:0]         a_wr_data;
    logic [3:0]          a_wr_len;
    logic                a_wr_ready;
    logic                a_rd_valid;
    logic [5:0]          a_rd_addr;
    logic [3:0]          a_rd_len;
    logic [15:0]         a_rd_data;
    logic                a_rd_data_valid;
    logic                a_busy;

    // Port B regular read + byte-enable write
    logic                b_wr_valid;
    logic [5:0]          b_wr_addr;
    logic [1:0]          b_wr_byte_en;
    logic [15:0]         b_wr_data;
    logic                b_rd_valid;
    logic [5:0]          b_rd_addr;
    logic [15:0]         b_rd_data;
    logic                b_rd_data_valid;
    logic                b_busy;

    // Port C regular read + byte-enable write
    logic                c_wr_valid;
    logic [5:0]          c_wr_addr;
    logic [1:0]          c_wr_byte_en;
    logic [15:0]         c_wr_data;
    logic                c_rd_valid;
    logic [5:0]          c_rd_addr;
    logic [15:0]         c_rd_data;
    logic                c_rd_data_valid;
    logic                c_busy;

    // DUT instantiation
    hbm_model #(
        .T           (logic [15:0]),
        .DEPTH       (64),
        .READ_LATENCY(3),
        .MAX_BURST   (8)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .a_wr_valid     (a_wr_valid),
        .a_wr_addr      (a_wr_addr),
        .a_wr_data      (a_wr_data),
        .a_wr_len       (a_wr_len),
        .a_wr_ready     (a_wr_ready),
        .a_rd_valid     (a_rd_valid),
        .a_rd_addr      (a_rd_addr),
        .a_rd_len       (a_rd_len),
        .a_rd_data      (a_rd_data),
        .a_rd_data_valid(a_rd_data_valid),
        .a_busy         (a_busy),
        .b_wr_valid     (b_wr_valid),
        .b_wr_addr      (b_wr_addr),
        .b_wr_byte_en   (b_wr_byte_en),
        .b_wr_data      (b_wr_data),
        .b_rd_valid     (b_rd_valid),
        .b_rd_addr      (b_rd_addr),
        .b_rd_data      (b_rd_data),
        .b_rd_data_valid(b_rd_data_valid),
        .b_busy         (b_busy),
        .c_wr_valid     (c_wr_valid),
        .c_wr_addr      (c_wr_addr),
        .c_wr_byte_en   (c_wr_byte_en),
        .c_wr_data      (c_wr_data),
        .c_rd_valid     (c_rd_valid),
        .c_rd_addr      (c_rd_addr),
        .c_rd_data      (c_rd_data),
        .c_rd_data_valid(c_rd_data_valid),
        .c_busy         (c_busy)
    );

    localparam int READ_LATENCY = 3;

    int cycle_cnt;
    int valid_count;
    int idx;
    int max_wait;
    int wait_count;
    int a_rd_count;
    int collect_cycles;
    logic [15:0] rd_val;
    logic [15:0] expected_vals [4];
    logic [15:0] write_vals [4];

    // Clock generator
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        // Initialize all signals
        rst_n = 0;
        a_wr_valid = 0;
        a_wr_addr = 0;
        a_wr_data = 0;
        a_wr_len = 0;
        a_rd_valid = 0;
        a_rd_addr = 0;
        a_rd_len = 0;
        b_wr_valid = 0;
        b_wr_addr = 0;
        b_wr_byte_en = 0;
        b_wr_data = 0;
        b_rd_valid = 0;
        b_rd_addr = 0;
        c_wr_valid = 0;
        c_wr_addr = 0;
        c_wr_byte_en = 0;
        c_wr_data = 0;
        c_rd_valid = 0;
        c_rd_addr = 0;

        // Reset for 2 cycles
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ====== Scenario 1: Port B basic write and read ======
        b_wr_valid = 1;
        b_wr_addr = 6'd10;
        b_wr_data = 16'hABCD;
        b_wr_byte_en = 2'b11;
        @(posedge clk);
        b_wr_valid = 0;

        b_rd_valid = 1;
        b_rd_addr = 6'd10;
        @(posedge clk);
        b_rd_valid = 0;

        cycle_cnt = 1;
        while (!b_rd_data_valid && cycle_cnt < 20) begin
            @(posedge clk);
            cycle_cnt += 1;
        end

        assert (cycle_cnt == READ_LATENCY)
            else $fatal(1, "Scenario 1 FAIL: b_rd_data_valid latency was %0d, expected %0d", cycle_cnt, READ_LATENCY);
        assert (b_rd_data == 16'hABCD)
            else $fatal(1, "Scenario 1 FAIL: b_rd_data mismatch, expected 0xABCD got 0x%04h", b_rd_data);
        $display("PASS: Port B basic write and read");

        // Wait for b_busy to clear
        while (b_busy) @(posedge clk);

        // ====== Scenario 2: Port C basic write and read ======
        c_wr_valid = 1;
        c_wr_addr = 6'd20;
        c_wr_data = 16'h1234;
        c_wr_byte_en = 2'b11;
        @(posedge clk);
        c_wr_valid = 0;

        c_rd_valid = 1;
        c_rd_addr = 6'd20;
        @(posedge clk);
        c_rd_valid = 0;

        while (!c_rd_data_valid) @(posedge clk);
        assert (c_rd_data == 16'h1234)
            else $fatal(1, "Scenario 2 FAIL: c_rd_data mismatch, expected 0x1234 got 0x%04h", c_rd_data);
        $display("PASS: Port C basic write and read");

        while (c_busy) @(posedge clk);

        // ====== Scenario 3: Port B byte-enable write low byte only ======
        b_wr_valid = 1;
        b_wr_addr = 6'd11;
        b_wr_data = 16'hFFFF;
        b_wr_byte_en = 2'b11;
        @(posedge clk);
        b_wr_valid = 0;

        @(posedge clk);

        b_wr_valid = 1;
        b_wr_addr = 6'd11;
        b_wr_data = 16'h00AB;
        b_wr_byte_en = 2'b01;  // Low byte only
        @(posedge clk);
        b_wr_valid = 0;

        @(posedge clk);

        b_rd_valid = 1;
        b_rd_addr = 6'd11;
        @(posedge clk);
        b_rd_valid = 0;

        while (!b_rd_data_valid) @(posedge clk);
        assert (b_rd_data == 16'hFFAB)
            else $fatal(1, "Scenario 3 FAIL: b_rd_data mismatch, expected 0xFFAB got 0x%04h", b_rd_data);
        $display("PASS: Port B byte-enable write low byte only");

        while (b_busy) @(posedge clk);

        // ====== Scenario 4: Port C byte-enable write high byte only ======
        c_wr_valid = 1;
        c_wr_addr = 6'd21;
        c_wr_data = 16'hFFFF;
        c_wr_byte_en = 2'b11;
        @(posedge clk);
        c_wr_valid = 0;

        @(posedge clk);

        c_wr_valid = 1;
        c_wr_addr = 6'd21;
        c_wr_data = 16'hCD00;
        c_wr_byte_en = 2'b10;  // High byte only
        @(posedge clk);
        c_wr_valid = 0;

        @(posedge clk);

        c_rd_valid = 1;
        c_rd_addr = 6'd21;
        @(posedge clk);
        c_rd_valid = 0;

        while (!c_rd_data_valid) @(posedge clk);
        assert (c_rd_data == 16'hCDFF)
            else $fatal(1, "Scenario 4 FAIL: c_rd_data mismatch, expected 0xCDFF got 0x%04h", c_rd_data);
        $display("PASS: Port C byte-enable write high byte only");

        while (c_busy) @(posedge clk);

        // ====== Scenario 5: Port A burst write then burst read ======
        $display("Scenario 5: Starting Port A burst write");
        a_wr_valid = 1;
        a_wr_addr = 6'd0;
        a_wr_len = 4'd4;
        a_wr_data = 16'h0001;
        @(posedge clk);
        $display("  Cycle 1: sent a_wr_len=4, a_wr_data=0x0001, a_wr_remaining should start");

        a_wr_data = 16'h0002;
        @(posedge clk);
        $display("  Cycle 2: a_wr_data=0x0002, a_wr_remaining=%0d, a_wr_active=%0b", dut.a_wr_remaining, dut.a_wr_active);

        a_wr_data = 16'h0003;
        @(posedge clk);
        $display("  Cycle 3: a_wr_data=0x0003, a_wr_remaining=%0d, a_wr_active=%0b", dut.a_wr_remaining, dut.a_wr_active);

        a_wr_data = 16'h0004;
        @(posedge clk);
        $display("  Cycle 4: a_wr_data=0x0004, a_wr_remaining=%0d, a_wr_active=%0b", dut.a_wr_remaining, dut.a_wr_active);

        a_wr_valid = 0;
        @(posedge clk);
        $display("  Cycle 5: a_wr_valid=0, a_wr_remaining=%0d, a_wr_active=%0b", dut.a_wr_remaining, dut.a_wr_active);

        // Wait for burst to complete
        $display("  Waiting for a_wr_ready (burst complete)...");
        wait_count = 0;
        while (!a_wr_ready && wait_count < 100) begin
            @(posedge clk);
            wait_count += 1;
            if (wait_count % 10 == 0) begin
                $display("    Wait cycle %0d: a_wr_ready=%0b, a_wr_remaining=%0d, a_wr_active=%0b", wait_count, a_wr_ready, dut.a_wr_remaining, dut.a_wr_active);
            end
        end
        if (wait_count >= 100) $fatal(1, "Scenario 5 TIMEOUT: a_wr_ready never asserted after 100 cycles");
        $display("  a_wr_ready asserted at cycle %0d", wait_count);
        @(posedge clk);

        // Issue burst read
        $display("Scenario 5: Starting Port A burst read");
        a_rd_valid = 1;
        a_rd_addr = 6'd0;
        a_rd_len = 4'd4;
        @(posedge clk);
        $display("  Read request issued");
        a_rd_valid = 0;

        // Collect 4 read values
        $display("Scenario 5: Collecting 4 burst read values");
        for (idx = 1; idx <= 4; idx++) begin
            $display("  Waiting for read[%0d]...", idx);
            wait_count = 0;
            while (!a_rd_data_valid && wait_count < 50) begin
                @(posedge clk);
                wait_count += 1;
            end
            if (wait_count >= 50) $fatal(1, "Scenario 5 TIMEOUT: a_rd_data_valid never asserted for read[%0d]", idx);
            rd_val = a_rd_data;
            $display("    Got data: 0x%04h, expected: 0x%04h", rd_val, idx);
            assert (rd_val == idx)
                else $fatal(1, "Scenario 5 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", idx, idx, rd_val);
            @(posedge clk);
        end
        $display("PASS: Port A burst write then burst read");

        while (a_busy) @(posedge clk);

        // ====== Scenario 6: Port A simultaneous burst read and burst write ======
        $display("Scenario 6: Pre-loading addresses 30-33 via Port B");
        for (idx = 0; idx < 4; idx++) begin
            b_wr_valid = 1;
            b_wr_addr = 6'd30 + idx;
            b_wr_data = 16'hAAAA + (idx * 16'h1111);
            b_wr_byte_en = 2'b11;
            @(posedge clk);
            $display("  Wrote addr[%0d]=%0d, data=0x%04h", idx, 30+idx, 16'hAAAA + (idx * 16'h1111));
        end
        b_wr_valid = 0;
        @(posedge clk);

        $display("Scenario 6: Waiting for b_busy to clear");
        while (b_busy) @(posedge clk);
        $display("Scenario 6: b_busy cleared, starting simultaneous Port A write and read");

        // Pre-set expected values for read
        expected_vals[0] = 16'hAAAA;
        expected_vals[1] = 16'hBBBB;
        expected_vals[2] = 16'hCCCC;
        expected_vals[3] = 16'hDDDD;

        a_rd_count = 0;

        // Simultaneously issue Port A write and read
        a_wr_valid = 1;
        a_wr_addr = 6'd40;
        a_wr_len = 4'd4;
        a_wr_data = 16'h0010;

        a_rd_valid = 1;
        a_rd_addr = 6'd30;
        a_rd_len = 4'd4;
        @(posedge clk);
        $display("  Cycle 1: a_wr_data=0x0010 a_rd_valid=1 a_rd_addr=30, a_wr_remaining=%0d a_rd_remaining=%0d", dut.a_wr_remaining, dut.a_rd_remaining);
        if (a_rd_data_valid) begin
            $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
            assert (a_rd_data == expected_vals[a_rd_count])
                else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
            a_rd_count += 1;
        end

        // Continue write burst
        a_wr_data = 16'h0020;
        @(posedge clk);
        $display("  Cycle 2: a_wr_data=0x0020 a_rd_data_valid=%0b a_rd_active=%0b", a_rd_data_valid, dut.a_rd_active);
        if (a_rd_data_valid) begin
            $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
            assert (a_rd_data == expected_vals[a_rd_count])
                else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
            a_rd_count += 1;
        end

        a_wr_data = 16'h0030;
        @(posedge clk);
        $display("  Cycle 3: a_wr_data=0x0030 a_rd_data_valid=%0b a_rd_active=%0b", a_rd_data_valid, dut.a_rd_active);
        if (a_rd_data_valid) begin
            $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
            assert (a_rd_data == expected_vals[a_rd_count])
                else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
            a_rd_count += 1;
        end

        a_wr_data = 16'h0040;
        @(posedge clk);
        $display("  Cycle 4: a_wr_data=0x0040 a_rd_data_valid=%0b a_rd_active=%0b", a_rd_data_valid, dut.a_rd_active);
        if (a_rd_data_valid) begin
            $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
            assert (a_rd_data == expected_vals[a_rd_count])
                else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
            a_rd_count += 1;
        end

        a_wr_valid = 0;
        a_rd_valid = 0;
        @(posedge clk);
        $display("  Cycle 5: a_wr_valid=0 a_rd_valid=0 a_rd_data_valid=%0b a_rd_active=%0b", a_rd_data_valid, dut.a_rd_active);
        if (a_rd_data_valid) begin
            $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
            assert (a_rd_data == expected_vals[a_rd_count])
                else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
            a_rd_count += 1;
        end

        // Collect any remaining read values
        collect_cycles = 0;
        while (a_rd_count < 4 && collect_cycles < 20) begin
            @(posedge clk);
            collect_cycles += 1;
            if (a_rd_data_valid) begin
                $display("  got a_rd_data=0x%04h at a_rd_count=%0d (expected 0x%04h)", a_rd_data, a_rd_count, expected_vals[a_rd_count]);
                assert (a_rd_data == expected_vals[a_rd_count])
                    else $fatal(1, "Scenario 6 FAIL: burst read[%0d] mismatch, expected 0x%04h got 0x%04h", a_rd_count, expected_vals[a_rd_count], a_rd_data);
                a_rd_count += 1;
            end
        end
        if (a_rd_count < 4) $fatal(1, "Scenario 6 TIMEOUT: only %0d A burst read values received", a_rd_count);


        // Wait for write to complete
        while (!a_wr_ready) @(posedge clk);
        @(posedge clk);
        @(posedge clk);

        // Read back written values via Port B
        write_vals[0] = 16'h0010;
        write_vals[1] = 16'h0020;
        write_vals[2] = 16'h0030;
        write_vals[3] = 16'h0040;
        for (idx = 0; idx < 4; idx++) begin
            b_rd_valid = 1;
            b_rd_addr = 6'd40 + idx;
            @(posedge clk);
            b_rd_valid = 0;

            while (!b_rd_data_valid) @(posedge clk);
            assert (b_rd_data == write_vals[idx])
                else $fatal(1, "Scenario 6 FAIL: Port B verify[%0d] mismatch, expected 0x%04h got 0x%04h", idx, write_vals[idx], b_rd_data);
            @(posedge clk);
        end
        $display("PASS: Port A simultaneous burst read and burst write");

        while (b_busy) @(posedge clk);

        // ====== Scenario 7: Sequential writes Port A then Port B same address ======
        // Issue Port A burst write to address 50
        a_wr_valid = 1;
        a_wr_addr = 6'd50;
        a_wr_len = 4'd1;
        a_wr_data = 16'h1111;
        @(posedge clk);
        a_wr_valid = 0;

        // Wait for Port A write to complete
        while (!a_wr_ready) @(posedge clk);
        @(posedge clk);

        // Then issue Port B write to same address
        b_wr_valid = 1;
        b_wr_addr = 6'd50;
        b_wr_data = 16'h2222;
        b_wr_byte_en = 2'b11;
        @(posedge clk);
        b_wr_valid = 0;

        @(posedge clk);

        // Read via Port B and verify Port B won (last write)
        b_rd_valid = 1;
        b_rd_addr = 6'd50;
        @(posedge clk);
        b_rd_valid = 0;

        while (!b_rd_data_valid) @(posedge clk);
        assert (b_rd_data == 16'h2222)
            else $fatal(1, "Scenario 7 FAIL: Sequential A then B write failed, expected 0x2222 got 0x%04h", b_rd_data);
        $display("PASS: Sequential writes Port A then Port B same address");

        while (b_busy) @(posedge clk);

        // ====== Scenario 8: Sequential writes Port A then Port C same address ======
        // Issue Port A burst write to address 51
        a_wr_valid = 1;
        a_wr_addr = 6'd51;
        a_wr_len = 4'd1;
        a_wr_data = 16'h3333;
        @(posedge clk);
        a_wr_valid = 0;

        while (!a_wr_ready) @(posedge clk);
        @(posedge clk);

        // Then issue Port C write to same address
        c_wr_valid = 1;
        c_wr_addr = 6'd51;
        c_wr_data = 16'h4444;
        c_wr_byte_en = 2'b11;
        @(posedge clk);
        c_wr_valid = 0;

        @(posedge clk);

        // Read via Port C and verify Port C won (last write)
        c_rd_valid = 1;
        c_rd_addr = 6'd51;
        @(posedge clk);
        c_rd_valid = 0;

        while (!c_rd_data_valid) @(posedge clk);
        assert (c_rd_data == 16'h4444)
            else $fatal(1, "Scenario 8 FAIL: Sequential A then C write failed, expected 0x4444 got 0x%04h", c_rd_data);
        $display("PASS: Sequential writes Port A then Port C same address");

        while (c_busy) @(posedge clk);

        // ====== Scenario 9: Port B and Port C merge on same address with non-overlapping byte enables ======
        b_wr_valid = 1;
        b_wr_addr = 6'd52;
        b_wr_data = 16'h0055;  // Low byte only
        b_wr_byte_en = 2'b01;  // Low byte enable

        c_wr_valid = 1;
        c_wr_addr = 6'd52;
        c_wr_data = 16'h6600;  // High byte only
        c_wr_byte_en = 2'b10;  // High byte enable
        @(posedge clk);

        b_wr_valid = 0;
        c_wr_valid = 0;

        @(posedge clk);

        // Read via Port B and verify merge (low byte from B, high byte from C)
        b_rd_valid = 1;
        b_rd_addr = 6'd52;
        @(posedge clk);
        b_rd_valid = 0;

        while (!b_rd_data_valid) @(posedge clk);
        assert (b_rd_data == 16'h6655)
            else $fatal(1, "Scenario 9 FAIL: Port B and C merge failed, expected 0x6655 got 0x%04h", b_rd_data);
        $display("PASS: Port B and Port C merge on same address with non-overlapping byte enables");

        while (b_busy) @(posedge clk);

        // ====== Scenario 10: Simultaneous reads on all three ports ======
        // Pre-load data
        b_wr_valid = 1;
        b_wr_addr = 6'd60;
        b_wr_data = 16'hDEAD;
        b_wr_byte_en = 2'b11;
        @(posedge clk);
        b_wr_valid = 0;

        c_wr_valid = 1;
        c_wr_addr = 6'd61;
        c_wr_data = 16'hBEEF;
        c_wr_byte_en = 2'b11;
        @(posedge clk);
        c_wr_valid = 0;

        b_wr_valid = 1;
        b_wr_addr = 6'd62;
        b_wr_data = 16'hCAFE;
        b_wr_byte_en = 2'b11;
        @(posedge clk);
        b_wr_valid = 0;

        while (b_busy || c_busy) @(posedge clk);

        // Issue simultaneous reads
        b_rd_valid = 1;
        b_rd_addr = 6'd60;

        c_rd_valid = 1;
        c_rd_addr = 6'd61;

        a_rd_valid = 1;
        a_rd_addr = 6'd62;
        a_rd_len = 4'd1;
        @(posedge clk);

        b_rd_valid = 0;
        c_rd_valid = 0;
        a_rd_valid = 0;

        // Collect all three results
        valid_count = 0;
        max_wait = 20;
        for (int i = 0; i < max_wait && valid_count < 3; i++) begin
            if (b_rd_data_valid) begin
                assert (b_rd_data == 16'hDEAD)
                    else $fatal(1, "Scenario 10 FAIL: Port B read mismatch, expected 0xDEAD got 0x%04h", b_rd_data);
                valid_count += 1;
            end
            if (c_rd_data_valid) begin
                assert (c_rd_data == 16'hBEEF)
                    else $fatal(1, "Scenario 10 FAIL: Port C read mismatch, expected 0xBEEF got 0x%04h", c_rd_data);
                valid_count += 1;
            end
            if (a_rd_data_valid) begin
                assert (a_rd_data == 16'hCAFE)
                    else $fatal(1, "Scenario 10 FAIL: Port A read mismatch, expected 0xCAFE got 0x%04h", a_rd_data);
                valid_count += 1;
            end
            @(posedge clk);
        end

        assert (valid_count == 3)
            else $fatal(1, "Scenario 10 FAIL: expected 3 valid reads, got %0d", valid_count);
        $display("PASS: Simultaneous reads on all three ports");

        while (a_busy || b_busy || c_busy) @(posedge clk);

        // ====== Scenario 11: Port B busy blocking ======
        b_rd_valid = 1;
        b_rd_addr = 6'd10;
        @(posedge clk);

        // Try to issue another read while busy (should be ignored per spec)
        b_rd_valid = 1;
        b_rd_addr = 6'd11;
        @(posedge clk);
        b_rd_valid = 0;

        // Collect only one valid pulse
        valid_count = 0;
        max_wait = 20;
        for (int i = 0; i < max_wait; i++) begin
            if (b_rd_data_valid) begin
                valid_count += 1;
                assert (b_rd_data == 16'hABCD)
                    else $fatal(1, "Scenario 11 FAIL: Port B read mismatch, expected 0xABCD got 0x%04h", b_rd_data);
            end
            @(posedge clk);
        end

        assert (valid_count == 1)
            else $fatal(1, "Scenario 11 FAIL: Port B busy blocking expected 1 valid pulse, got %0d", valid_count);
        $display("PASS: Port B busy blocking");

        while (b_busy) @(posedge clk);

        // ====== Scenario 12: Reset behavior ======
        // Issue Port A burst write
        a_wr_valid = 1;
        a_wr_addr = 6'd0;
        a_wr_len = 4'd4;
        a_wr_data = 16'h0001;
        @(posedge clk);

        a_wr_data = 16'h0002;
        @(posedge clk);

        a_wr_valid = 0;

        // Assert reset
        rst_n = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Verify busy signals are clear
        assert (a_busy == 0)
            else $fatal(1, "Scenario 12 FAIL: a_busy not low after reset");
        assert (b_busy == 0)
            else $fatal(1, "Scenario 12 FAIL: b_busy not low after reset");
        assert (c_busy == 0)
            else $fatal(1, "Scenario 12 FAIL: c_busy not low after reset");

        // Read from address 0 and verify memory survived reset
        b_rd_valid = 1;
        b_rd_addr = 6'd0;
        @(posedge clk);
        b_rd_valid = 0;

        while (!b_rd_data_valid) @(posedge clk);
        assert (b_rd_data == 16'h0001)
            else $fatal(1, "Scenario 12 FAIL: memory should survive reset, expected 0x0001 got 0x%04h", b_rd_data);
        $display("PASS: Reset behavior");

        $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
