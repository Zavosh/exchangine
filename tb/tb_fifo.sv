// tb_fifo.sv — directed testbench for fifo.sv

`timescale 1ns/1ps

module tb_fifo;

    // Signals
    logic        clk;
    logic        rst_n;
    logic [7:0]  din;
    logic        push;
    logic        full;
    logic [7:0]  dout;
    logic        pop;
    logic        empty;

    // DUT instantiation
    fifo #(
        .T    (logic [7:0]),
        .DEPTH(8)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .din  (din),
        .push (push),
        .full (full),
        .dout (dout),
        .pop  (pop),
        .empty(empty)
    );

    // Clock generation
    always #5 clk = ~clk;

    // Test stimulus
    initial begin
        // Initialize
        clk = 0;
        rst_n = 0;
        din = 0;
        push = 0;
        pop = 0;

        // Reset for 2 cycles
        repeat(2) @(posedge clk);
        rst_n = 1;

        // Scenario 1 — Basic push and pop
        @(posedge clk);
        push = 1; din = 8'h01;
        @(posedge clk);
        push = 1; din = 8'h02;
        @(posedge clk);
        push = 1; din = 8'h03;
        @(posedge clk);
        push = 0;

        // Check before pops
        @(posedge clk);
        assert (dout == 8'h01) else $fatal(1, "FAIL: basic push/pop - dout != 0x01");
        pop = 1;
        @(posedge clk);
        assert (dout == 8'h02) else $fatal(1, "FAIL: basic push/pop - dout != 0x02");
        pop = 1;
        @(posedge clk);
        assert (dout == 8'h03) else $fatal(1, "FAIL: basic push/pop - dout != 0x03");
        pop = 1;
        @(posedge clk);
        pop = 0;
        assert (empty) else $fatal(1, "FAIL: basic push/pop - not empty after pops");
        $display("PASS: basic push/pop");

        // Scenario 2 — Full detection
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            push = 1; din = 8'h10 + i;
        end
        @(posedge clk);
        push = 0;
        assert (full) else $fatal(1, "FAIL: full detection - not full after 8 pushes");
        @(posedge clk);
        push = 1; din = 8'hFF;
        @(posedge clk);
        push = 0;
        assert (full) else $fatal(1, "FAIL: full detection - not full after extra push");
        assert (dout == 8'h10) else $fatal(1, "FAIL: full detection - dout changed");
        $display("PASS: full detection");

        // Scenario 3 — Empty detection
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            pop = 1;
        end
        @(posedge clk);
        pop = 0;
        assert (empty) else $fatal(1, "FAIL: empty detection - not empty after 8 pops");
        @(posedge clk);
        pop = 1;
        @(posedge clk);
        pop = 0;
        assert (empty) else $fatal(1, "FAIL: empty detection - not empty after extra pop");
        $display("PASS: empty detection");

        // Scenario 4 — Simultaneous push and pop
        @(posedge clk);
        push = 1; din = 8'h20;
        @(posedge clk);
        push = 1; din = 8'h21;
        @(posedge clk);
        push = 1; din = 8'h22;
        @(posedge clk);
        push = 1; din = 8'h23;
        @(posedge clk);
        push = 0;
        // Now 4 entries: 20,21,22,23
        @(posedge clk);
        push = 1; din = 8'h24;
        pop = 1;
        assert (dout == 8'h20) else $fatal(1, "FAIL: simultaneous push/pop - dout != 0x20");
        @(posedge clk);
        push = 0; pop = 0;
        assert (dout == 8'h21) else $fatal(1, "FAIL: simultaneous push/pop - dout != 0x21");
        // Should still have 4 entries, since push and pop
        assert (((dut.wr_ptr - dut.rd_ptr) & 15) == 4) else $fatal(1, "FAIL: simultaneous push/pop - fill level not 4");
        $display("PASS: simultaneous push/pop");

        // Scenario 5 — Reset behavior
        @(posedge clk);
        push = 1; din = 8'h30;
        @(posedge clk);
        push = 1; din = 8'h31;
        @(posedge clk);
        push = 1; din = 8'h32;
        @(posedge clk);
        push = 0;
        @(posedge clk);
        rst_n = 0;
        @(posedge clk);
        rst_n = 1;
        assert (empty) else $fatal(1, "FAIL: reset behavior - not empty after reset");
        @(posedge clk);
        push = 1; din = 8'h40;
        @(posedge clk);
        push = 0; pop = 1;
        assert (dout == 8'h40) else $fatal(1, "FAIL: reset behavior - dout != 0x40");
        @(posedge clk);
        pop = 0;
        $display("PASS: reset behavior");

        // Scenario 6 — Wrap-around
        for (int i = 0; i < 16; i++) begin
            @(posedge clk);
            if (i % 2 == 0) begin
                push = 1; pop = 0;
                din = 8'h50 + (i/2);
            end else begin
                pop = 1; push = 0;
                assert (dout == 8'h50 + ((i-1)/2)) else $fatal(1, "FAIL: wrap-around - dout mismatch at cycle %0d", i);
            end
        end
        $display("PASS: wrap-around");

        $display("ALL TESTS PASSED");
        $finish;
    end

endmodule