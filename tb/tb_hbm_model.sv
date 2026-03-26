// tb_hbm_model.sv — directed testbench for hbm_model.sv
`timescale 1ns/1ps

module tb_hbm_model;
    // Testbench signals
    logic clk;
    logic rst_n;
    logic wr_valid;
    logic [5:0] wr_addr;
    logic [7:0] wr_data;
    logic rd_valid;
    logic [5:0] rd_addr;
    logic [7:0] rd_data;
    logic rd_data_valid;
    logic busy;

    // DUT instantiation
    hbm_model #(
        .T           (logic [7:0]),
        .DEPTH       (64),
        .READ_LATENCY(3)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_valid     (wr_valid),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .rd_valid     (rd_valid),
        .rd_addr      (rd_addr),
        .rd_data      (rd_data),
        .rd_data_valid(rd_data_valid),
        .busy         (busy)
    );

    localparam int READ_LATENCY = 3;

    int cycle_cnt;
    int seen;
    int max_wait;

    // Clock generator
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        // Initialize signals
        rst_n = 0;
        wr_valid = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_valid = 0;
        rd_addr = 0;

        // Reset for 2 cycles
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Scenario 1 — Basic write and read
        wr_valid = 1;
        wr_addr = 6'd0;
        wr_data = 8'hAB;
        rd_valid = 0;
        @(posedge clk);
        wr_valid = 0;

        rd_valid = 1;
        rd_addr = 6'd0;
        @(posedge clk);
        rd_valid = 0;

        cycle_cnt = 1;
        while (!rd_data_valid) begin
            @(posedge clk);
            cycle_cnt += 1;
        end

        assert (cycle_cnt == READ_LATENCY) else $fatal(1, "Scenario 1: rd_data_valid not seen after %0d cycles, expected %0d", cycle_cnt, READ_LATENCY);
        assert (rd_data == 8'hAB) else $fatal(1, "Scenario 1: rd_data mismatch expected 0xAB got 0x%0h", rd_data);
        assert (busy == 0) else $fatal(1, "Scenario 1: busy not low on rd_data_valid cycle");
        $display("PASS: basic write and read");

        // Ensure pipeline is idle before next scenario
        while (busy) @(posedge clk);

        // Scenario 2 — Multiple sequential reads
        for (int i = 0; i < 3; i++) begin
            wr_valid = 1;
            wr_addr = i;
            wr_data = 8'h01 + i;
            rd_valid = 0;
            @(posedge clk);
            wr_valid = 0;
            @(posedge clk);
        end

        for (int i = 0; i < 3; i++) begin
            rd_valid = 1;
            rd_addr = i;
            @(posedge clk);
            rd_valid = 0;

            while (!rd_data_valid) @(posedge clk);
            assert (rd_data == (8'h01 + i)) else $fatal(1, "Scenario 2: rd_data mismatch at addr %0d expected 0x%0h got 0x%0h", i, 8'h01 + i, rd_data);
            while (busy) @(posedge clk);
        end

        $display("PASS: sequential reads");

        // Scenario 3 — Busy blocking
        while (busy) @(posedge clk);

        rd_valid = 1;
        rd_addr = 0;
        @(posedge clk);
        rd_valid = 0;

        @(posedge clk);
        rd_valid = 1;
        rd_addr = 1;
        @(posedge clk);
        rd_valid = 0;

        seen = 0;
        max_wait = 20;
        for (int i = 0; i < max_wait; i++) begin
            if (rd_data_valid) begin
                seen += 1;
                assert (seen == 1) else $fatal(1, "Scenario 3: rd_data_valid pulse count > 1");
                assert (rd_data == 8'h01) else $fatal(1, "Scenario 3: rd_data should be 0x01, got 0x%0h", rd_data);
            end
            @(posedge clk);
        end

        assert (seen == 1) else $fatal(1, "Scenario 3: Expected exactly one rd_data_valid, saw %0d", seen);
        $display("PASS: busy blocking");

        // Scenario 4 — Write during read
        while (busy) @(posedge clk);

        wr_valid = 1;
        wr_addr = 5;
        wr_data = 8'hAA;
        rd_valid = 0;
        @(posedge clk);
        wr_valid = 0;

        rd_valid = 1;
        rd_addr = 5;
        @(posedge clk);
        rd_valid = 0;

        @(posedge clk);
        assert (busy == 1) else $fatal(1, "Scenario 4: expected busy while first read is in flight");

        wr_valid = 1;
        wr_addr = 5;
        wr_data = 8'hBB;
        @(posedge clk);
        wr_valid = 0;

        while (!rd_data_valid) @(posedge clk);
        assert (rd_data == 8'hAA) else $fatal(1, "Scenario 4: first read should return pre-write value 0xAA got 0x%0h", rd_data);

        while (busy) @(posedge clk);

        rd_valid = 1;
        rd_addr = 5;
        @(posedge clk);
        rd_valid = 0;

        while (!rd_data_valid) @(posedge clk);
        assert (rd_data == 8'hBB) else $fatal(1, "Scenario 4: second read should return 0xBB got 0x%0h", rd_data);
        $display("PASS: write during read (no forwarding)");
        $display("NOTE: write-during-read returns pre-write value by design");

        // Scenario 5 — Reset during idle
        while (busy) @(posedge clk);

        wr_valid = 1;
        wr_addr = 3;
        wr_data = 8'h42;
        rd_valid = 0;
        @(posedge clk);
        wr_valid = 0;

        rst_n = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        assert (busy == 0) else $fatal(1, "Scenario 5: busy not low after reset");

        rd_valid = 1;
        rd_addr = 3;
        @(posedge clk);
        rd_valid = 0;

        while (!rd_data_valid) @(posedge clk);
        assert (rd_data == 8'h42) else $fatal(1, "Scenario 5: rd_data mismatch expected 0x42 got 0x%0h", rd_data);
        $display("PASS: reset during idle");

        // Scenario 6 — Back-to-back reads
        while (busy) @(posedge clk);

        rd_valid = 1;
        rd_addr = 0;
        @(posedge clk);
        rd_valid = 0;

        while (busy) @(posedge clk);
        assert (rd_data_valid) else $fatal(1, "Scenario 6: expected rd_data_valid after first read");
        assert (rd_data == 8'h01) else $fatal(1, "Scenario 6: first back-to-back read mismatch expected 0x01 got 0x%0h", rd_data);

        rd_valid = 1;
        rd_addr = 1;
        @(posedge clk);
        rd_valid = 0;

        while (busy) @(posedge clk);
        assert (rd_data_valid) else $fatal(1, "Scenario 6: expected rd_data_valid after second read");
        assert (rd_data == 8'h02) else $fatal(1, "Scenario 6: second back-to-back read mismatch expected 0x02 got 0x%0h", rd_data);

        $display("PASS: back-to-back reads");

        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
