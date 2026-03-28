// tb_order_pool.sv — directed testbench for order_pool.sv

`timescale 1ns / 1ps

module tb_order_pool;
    import ob_pkg::*;

    // ==================== Clock and Reset ====================
    logic                    clk;
    logic                    rst_n;

    // ==================== DUT Interface ====================
    pool_op_t                op_in;
    logic                    op_valid;
    logic                    op_ready;
    pool_update_t            pool_update;
    logic                    pool_update_valid;
    execution_t              exec_out;
    logic                    exec_valid;
    ack_t                    ack_out;
    logic                    ack_valid;

    // ==================== DUT Instantiation ====================
    order_pool dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .op_in            (op_in),
        .op_valid         (op_valid),
        .op_ready         (op_ready),
        .pool_update      (pool_update),
        .pool_update_valid(pool_update_valid),
        .exec_out         (exec_out),
        .exec_valid       (exec_valid),
        .ack_out          (ack_out),
        .ack_valid        (ack_valid)
    );

    // ==================== Test Helper Parameters ====================
    localparam logic [PRICE_WIDTH-1:0]    TEST_PRICE_BID = 16'h0064; // 100 cents
    localparam logic [PRICE_WIDTH-1:0]    TEST_PRICE_ASK = 16'h0066; // 102 cents
    localparam logic [ORDER_ID_WIDTH-1:0] ID_A = 8'h01;
    localparam logic [ORDER_ID_WIDTH-1:0] ID_B = 8'h02;
    localparam logic [ORDER_ID_WIDTH-1:0] ID_C = 8'h03;
    localparam logic [ORDER_ID_WIDTH-1:0] ID_T1 = 8'hA1; // taker IDs
    localparam logic [ORDER_ID_WIDTH-1:0] ID_T2 = 8'hA2;

    // ==================== Helper Tasks ====================

    task automatic send_op(input pool_op_t op);
        op_in    = op;
        op_valid = 1;
        $display("%t: send_op request op_type=%0d order_id=%0h qty=%0d list_ptr=%0h", $time, op.op_type, op.order_id, op.qty, op.list_ptr);

        // Wait for receiver to indicate readiness in-cycle.
        while (!op_ready) begin
            @(posedge clk);
            $display("%t: send_op waiting for op_ready", $time);
        end

        // Keep op_valid high for one clock edge to complete transfer.
        @(posedge clk);

        op_valid = 0;
        op_in    = '0;
        $display("%t: send_op complete", $time);
    endtask

    task automatic wait_ack(output ack_t ack);
        int timeout = 0;
        $display("%t: wait_ack entered", $time);
        while (!ack_valid) begin
            @(posedge clk);
            timeout += 1;
            if (timeout > 200) $fatal(1, "FAIL: wait_ack timeout");
            $display("%t: wait_ack waiting (ack_valid=%0b)", $time, ack_valid);
        end
        ack = ack_out;
        $display("%t: wait_ack got ack accepted=%0b order_id=%0h msg_type=%0d remaining_qty=%0d", $time, ack.accepted, ack.order_id, ack.msg_type, ack.remaining_qty);
    endtask

    task automatic wait_pool_update(output pool_update_t pu);
        int timeout = 0;
        $display("%t: wait_pool_update entered", $time);
        while (!pool_update_valid) begin
            @(posedge clk);
            timeout += 1;
            if (timeout > 200) $fatal(1, "FAIL: wait_pool_update timeout");
            $display("%t: wait_pool_update waiting (pool_update_valid=%0b)", $time, pool_update_valid);
        end
        pu = pool_update;
        $display("%t: wait_pool_update got pu is_cancel=%0b price=%0h side=%0b head=%0h freed=%0h qty=%0d", $time, pu.is_cancel, pu.price, pu.side, pu.head_order_id, pu.freed_order_id, pu.qty);
    endtask

    task automatic wait_exec(output execution_t ex);
        int timeout = 0;
        $display("%t: wait_exec entered", $time);
        while (!exec_valid) begin
            @(posedge clk);
            timeout += 1;
            if (timeout > 200) $fatal(1, "FAIL: wait_exec timeout");
            $display("%t: wait_exec waiting (exec_valid=%0b)", $time, exec_valid);
        end
        ex = exec_out;
        $display("%t: wait_exec got exec maker_id=%0h taker_id=%0h fill_qty=%0d fill_price=%0h maker_side=%0b", $time, ex.maker_id, ex.taker_id, ex.fill_qty, ex.fill_price, ex.maker_side);
    endtask

    // ==================== Clock Generation ====================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ==================== Reset Generation ====================
    initial begin
        rst_n = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
    end

    // ==================== Main Test Block ====================
    initial begin
        // Initialize all inputs
        op_in    = '0;
        op_valid = 1'b0;

        // Wait for reset to complete
        @(posedge clk iff rst_n);
        @(posedge clk);

        // ===== SCENARIO 1: OP_ADD single order to empty level =====
        begin
            pool_op_t op;
            ack_t ack;

            $display("[TEST] Scenario 1: OP_ADD single order to empty level");
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            assert (ack.accepted == 1) else $fatal(1, "FAIL: Scenario 1 — accepted should be 1");
            assert (ack.order_id == ID_A) else $fatal(1, "FAIL: Scenario 1 — order_id mismatch");
            assert (ack.msg_type == MSG_ADD) else $fatal(1, "FAIL: Scenario 1 — msg_type should be MSG_ADD");
            assert (ack.remaining_qty == 10) else $fatal(1, "FAIL: Scenario 1 — remaining_qty should be 10");
            $display("PASS: Scenario 1");
        end

        // ===== SCENARIO 2: OP_ADD second order, verify chain via OP_MATCH =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;

            $display("[TEST] Scenario 2: OP_ADD second order to same level, verify chain via OP_MATCH");

            // Add second order
            op = '{
                op_type: OP_ADD,
                order_id: ID_B,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            assert (ack.accepted == 1) else $fatal(1, "FAIL: Scenario 2 — second ADD accepted should be 1");
            assert (ack.order_id == ID_B) else $fatal(1, "FAIL: Scenario 2 — order_id mismatch");
            assert (ack.msg_type == MSG_ADD) else $fatal(1, "FAIL: Scenario 2 — msg_type should be MSG_ADD");
            assert (ack.remaining_qty == 5) else $fatal(1, "FAIL: Scenario 2 — remaining_qty should be 5");

            // Match against both orders
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 15,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            // First execution (ID_A)
            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 2 — first exec maker_id should be ID_A");
            assert (exec.taker_id == ID_T1) else $fatal(1, "FAIL: Scenario 2 — first exec taker_id should be ID_T1");
            assert (exec.fill_qty == 10) else $fatal(1, "FAIL: Scenario 2 — first fill_qty should be 10");
            assert (exec.fill_price == TEST_PRICE_BID) else $fatal(1, "FAIL: Scenario 2 — first fill_price mismatch");

            // First pool_update (ID_A freed)
            wait_pool_update(pu);
            assert (pu.is_cancel == 0) else $fatal(1, "FAIL: Scenario 2 — first pool_update is_cancel should be 0");
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 2 — first freed_order_id should be ID_A");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 2 — first head_order_id should be ID_B");

            // Second execution (ID_B)
            wait_exec(exec);
            assert (exec.maker_id == ID_B) else $fatal(1, "FAIL: Scenario 2 — second exec maker_id should be ID_B");
            assert (exec.taker_id == ID_T1) else $fatal(1, "FAIL: Scenario 2 — second exec taker_id should be ID_T1");
            assert (exec.fill_qty == 5) else $fatal(1, "FAIL: Scenario 2 — second fill_qty should be 5");
            assert (exec.fill_price == TEST_PRICE_BID) else $fatal(1, "FAIL: Scenario 2 — second fill_price mismatch");

            // Second pool_update (ID_B freed, level depleted)
            wait_pool_update(pu);
            assert (pu.is_cancel == 0) else $fatal(1, "FAIL: Scenario 2 — second pool_update is_cancel should be 0");
            assert (pu.freed_order_id == ID_B) else $fatal(1, "FAIL: Scenario 2 — second freed_order_id should be ID_B");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 2 — second head_order_id should equal freed (level depleted)");

            $display("PASS: Scenario 2");
        end

        // ===== SCENARIO 3: OP_ADD_FAIL =====
        begin
            pool_op_t op;
            ack_t ack;

            $display("[TEST] Scenario 3: OP_ADD_FAIL");
            op = '{
                op_type: OP_ADD_FAIL,
                order_id: ID_C,
                qty: 7,
                list_ptr: '0,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            assert (ack.accepted == 0) else $fatal(1, "FAIL: Scenario 3 — accepted should be 0");
            assert (ack.order_id == ID_C) else $fatal(1, "FAIL: Scenario 3 — order_id mismatch");
            assert (ack.msg_type == MSG_ADD) else $fatal(1, "FAIL: Scenario 3 — msg_type should be MSG_ADD");
            assert (ack.remaining_qty == 7) else $fatal(1, "FAIL: Scenario 3 — remaining_qty should be 7");
            $display("PASS: Scenario 3");
        end

        // ===== SCENARIO 4: OP_MARKET_FAIL =====
        begin
            pool_op_t op;
            ack_t ack;

            $display("[TEST] Scenario 4: OP_MARKET_FAIL");
            op = '{
                op_type: OP_MARKET_FAIL,
                order_id: ID_T1,
                qty: 20,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            assert (ack.accepted == 0) else $fatal(1, "FAIL: Scenario 4 — accepted should be 0");
            assert (ack.msg_type == MSG_MARKET) else $fatal(1, "FAIL: Scenario 4 — msg_type should be MSG_MARKET");
            assert (ack.remaining_qty == 20) else $fatal(1, "FAIL: Scenario 4 — remaining_qty should be 20");
            $display("PASS: Scenario 4");
        end

        // ===== SCENARIO 5: OP_CANCEL live order =====
        begin
            pool_op_t op;
            ack_t ack;
            pool_update_t pu;

            $display("[TEST] Scenario 5: OP_CANCEL live order");

            // Add order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Cancel order
            op = '{
                op_type: OP_CANCEL,
                order_id: ID_A,
                qty: '0,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);

            wait_pool_update(pu);
            assert (pu.is_cancel == 1) else $fatal(1, "FAIL: Scenario 5 — pool_update is_cancel should be 1");
            assert (pu.price == TEST_PRICE_BID) else $fatal(1, "FAIL: Scenario 5 — pool_update price mismatch");
            assert (pu.side == SIDE_BID) else $fatal(1, "FAIL: Scenario 5 — pool_update side mismatch");
            assert (pu.qty == 10) else $fatal(1, "FAIL: Scenario 5 — pool_update qty should be 10");

            wait_ack(ack);
            assert (ack.accepted == 1) else $fatal(1, "FAIL: Scenario 5 — cancel accepted should be 1");
            assert (ack.order_id == ID_A) else $fatal(1, "FAIL: Scenario 5 — cancel order_id mismatch");
            assert (ack.msg_type == MSG_CANCEL) else $fatal(1, "FAIL: Scenario 5 — msg_type should be MSG_CANCEL");
            assert (ack.remaining_qty == 10) else $fatal(1, "FAIL: Scenario 5 — cancel remaining_qty should be 10");

            $display("PASS: Scenario 5");
        end

        // ===== SCENARIO 6: OP_CANCEL non-existent order =====
        begin
            pool_op_t op;
            ack_t ack;
            pool_update_t pu;

            $display("[TEST] Scenario 6: OP_CANCEL non-existent order");

            op = '{
                op_type: OP_CANCEL,
                order_id: 8'hFF,
                qty: '0,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);

            wait_pool_update(pu);
            assert (pu.qty == 0) else $fatal(1, "FAIL: Scenario 6 — pool_update qty should be 0");

            wait_ack(ack);
            assert (ack.accepted == 0) else $fatal(1, "FAIL: Scenario 6 — cancel accepted should be 0");
            assert (ack.msg_type == MSG_CANCEL) else $fatal(1, "FAIL: Scenario 6 — msg_type should be MSG_CANCEL");
            assert (ack.remaining_qty == 0) else $fatal(1, "FAIL: Scenario 6 — cancel remaining_qty should be 0");

            $display("PASS: Scenario 6");
        end

        // ===== SCENARIO 7: OP_CANCEL already cancelled order =====
        begin
            pool_op_t op;
            ack_t ack;
            pool_update_t pu;

            $display("[TEST] Scenario 7: OP_CANCEL already cancelled order");

            // Add order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // First cancel
            op = '{
                op_type: OP_CANCEL,
                order_id: ID_A,
                qty: '0,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_pool_update(pu);
            wait_ack(ack);

            // Second cancel
            op = '{
                op_type: OP_CANCEL,
                order_id: ID_A,
                qty: '0,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);

            wait_pool_update(pu);
            assert (pu.qty == 0) else $fatal(1, "FAIL: Scenario 7 — second pool_update qty should be 0");

            wait_ack(ack);
            assert (ack.accepted == 0) else $fatal(1, "FAIL: Scenario 7 — second cancel accepted should be 0");

            $display("PASS: Scenario 7");
        end

        // ===== SCENARIO 8: OP_MATCH single order, taker exactly fills =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;

            $display("[TEST] Scenario 8: OP_MATCH single order, taker exactly fills");

            // Add order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_ASK,
                maker_side: SIDE_ASK
            };
            send_op(op);
            wait_ack(ack);

            // Match exactly
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_ASK,
                maker_side: SIDE_ASK
            };
            send_op(op);

            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 8 — maker_id mismatch");
            assert (exec.taker_id == ID_T1) else $fatal(1, "FAIL: Scenario 8 — taker_id mismatch");
            assert (exec.fill_qty == 10) else $fatal(1, "FAIL: Scenario 8 — fill_qty should be 10");
            assert (exec.fill_price == TEST_PRICE_ASK) else $fatal(1, "FAIL: Scenario 8 — fill_price mismatch");
            assert (exec.maker_side == SIDE_ASK) else $fatal(1, "FAIL: Scenario 8 — maker_side mismatch");

            wait_pool_update(pu);
            assert (pu.is_cancel == 0) else $fatal(1, "FAIL: Scenario 8 — pool_update is_cancel should be 0");
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 8 — freed_order_id should be ID_A");
            assert (pu.head_order_id == ID_A) else $fatal(1, "FAIL: Scenario 8 — head_order_id should equal freed (tail depleted)");

            $display("PASS: Scenario 8");
        end

        // ===== SCENARIO 9: OP_MATCH single order, taker partially fills =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            int cycle_count;

            $display("[TEST] Scenario 9: OP_MATCH single order, taker partially fills");

            // Add order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_ASK,
                maker_side: SIDE_ASK
            };
            send_op(op);
            wait_ack(ack);

            // Match partially
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 4,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_ASK,
                maker_side: SIDE_ASK
            };
            send_op(op);

            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 9 — maker_id mismatch");
            assert (exec.taker_id == ID_T1) else $fatal(1, "FAIL: Scenario 9 — taker_id mismatch");
            assert (exec.fill_qty == 4) else $fatal(1, "FAIL: Scenario 9 — fill_qty should be 4");
            assert (exec.fill_price == TEST_PRICE_ASK) else $fatal(1, "FAIL: Scenario 9 — fill_price mismatch");

            // Assert no pool_update within 5 cycles
            cycle_count = 0;
            repeat (5) begin
                @(posedge clk);
                cycle_count++;
                assert (pool_update_valid == 0) else $fatal(1, "FAIL: Scenario 9 — unexpected pool_update_valid on cycle");
            end

            $display("PASS: Scenario 9");
        end

        // ===== SCENARIO 10: OP_MATCH taker sweeps two orders =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;

            $display("[TEST] Scenario 10: OP_MATCH taker sweeps two orders");

            // Add first order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Add second order
            op = '{
                op_type: OP_ADD,
                order_id: ID_B,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Match sweeps both
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 13,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            // First execution (ID_A)
            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 10 — first maker_id should be ID_A");
            assert (exec.fill_qty == 5) else $fatal(1, "FAIL: Scenario 10 — first fill_qty should be 5");

            // First pool_update
            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 10 — first freed_order_id should be ID_A");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 10 — first head_order_id should be ID_B");

            // Second execution (ID_B)
            wait_exec(exec);
            assert (exec.maker_id == ID_B) else $fatal(1, "FAIL: Scenario 10 — second maker_id should be ID_B");
            assert (exec.fill_qty == 8) else $fatal(1, "FAIL: Scenario 10 — second fill_qty should be 8");

            // Second pool_update
            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_B) else $fatal(1, "FAIL: Scenario 10 — second freed_order_id should be ID_B");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 10 — second head_order_id should equal freed (tail depleted)");

            $display("PASS: Scenario 10");
        end

        // ===== SCENARIO 11: OP_MATCH sweeps first, partially fills second =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;
            int cycle_count;

            $display("[TEST] Scenario 11: OP_MATCH sweeps first, partially fills second");

            // Add first order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Add second order
            op = '{
                op_type: OP_ADD,
                order_id: ID_B,
                qty: 10,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Match takes 5 from first, 3 from second
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            // First execution (ID_A)
            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 11 — first maker_id should be ID_A");
            assert (exec.fill_qty == 5) else $fatal(1, "FAIL: Scenario 11 — first fill_qty should be 5");

            // First pool_update
            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 11 — freed_order_id should be ID_A");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 11 — head_order_id should be ID_B");

            // Second execution (ID_B, partial)
            wait_exec(exec);
            assert (exec.maker_id == ID_B) else $fatal(1, "FAIL: Scenario 11 — second maker_id should be ID_B");
            assert (exec.fill_qty == 3) else $fatal(1, "FAIL: Scenario 11 — second fill_qty should be 3");

            // Assert no pool_update within 5 cycles (ID_B still has qty)
            cycle_count = 0;
            repeat (5) begin
                @(posedge clk);
                cycle_count++;
                assert (pool_update_valid == 0) else $fatal(1, "FAIL: Scenario 11 — unexpected pool_update_valid");
            end

            $display("PASS: Scenario 11");
        end

        // ===== SCENARIO 12: OP_MATCH encounters cancelled slot mid-walk =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;

            $display("[TEST] Scenario 12: OP_MATCH encounters cancelled slot mid-walk");

            // Add first order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Add second order
            op = '{
                op_type: OP_ADD,
                order_id: ID_B,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Cancel first order
            op = '{
                op_type: OP_CANCEL,
                order_id: ID_A,
                qty: '0,
                list_ptr: '0,
                fill_price: '0,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_pool_update(pu);
            wait_ack(ack);

            // Match starting from stale head (ID_A is now cancelled)
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            // Should skip ID_A and find ID_B
            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 12 — should free cancelled slot ID_A");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 12 — head should advance to ID_B");

            // Execution for ID_B
            wait_exec(exec);
            assert (exec.maker_id == ID_B) else $fatal(1, "FAIL: Scenario 12 — maker_id should be ID_B");
            assert (exec.fill_qty == 8) else $fatal(1, "FAIL: Scenario 12 — fill_qty should be 8");

            // Pool update for ID_B
            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_B) else $fatal(1, "FAIL: Scenario 12 — freed_order_id should be ID_B");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 12 — head_order_id should equal freed (tail depleted)");

            $display("PASS: Scenario 12");
        end

        // ===== SCENARIO 13: OP_MATCH back-to-back with stale head =====
        begin
            pool_op_t op;
            ack_t ack;
            execution_t exec;
            pool_update_t pu;

            $display("[TEST] Scenario 13: OP_MATCH back-to-back with stale head");

            // Add first order
            op = '{
                op_type: OP_ADD,
                order_id: ID_A,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // Add second order
            op = '{
                op_type: OP_ADD,
                order_id: ID_B,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);
            wait_ack(ack);

            // First match: take all of ID_A
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T1,
                qty: 5,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            wait_exec(exec);
            assert (exec.maker_id == ID_A) else $fatal(1, "FAIL: Scenario 13 — first exec maker_id should be ID_A");
            assert (exec.fill_qty == 5) else $fatal(1, "FAIL: Scenario 13 — first fill_qty should be 5");

            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_A) else $fatal(1, "FAIL: Scenario 13 — first freed_order_id should be ID_A");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 13 — first head_order_id should be ID_B");

            // Second match: immediately with stale head (still pointing to ID_A)
            op = '{
                op_type: OP_MATCH,
                order_id: ID_T2,
                qty: 8,
                list_ptr: ID_A,
                fill_price: TEST_PRICE_BID,
                maker_side: SIDE_BID
            };
            send_op(op);

            // Second match should skip invalid ID_A, no pool_update for it
            // Then match ID_B
            wait_exec(exec);
            assert (exec.maker_id == ID_B) else $fatal(1, "FAIL: Scenario 13 — second exec maker_id should be ID_B");
            assert (exec.fill_qty == 8) else $fatal(1, "FAIL: Scenario 13 — second fill_qty should be 8");

            wait_pool_update(pu);
            assert (pu.freed_order_id == ID_B) else $fatal(1, "FAIL: Scenario 13 — freed_order_id should be ID_B");
            assert (pu.head_order_id == ID_B) else $fatal(1, "FAIL: Scenario 13 — head_order_id should equal freed (tail depleted)");

            $display("PASS: Scenario 13");
        end

        // ===== Test completion =====
        $display("\n========================================");
        $display("ALL TESTS PASSED");
        $display("========================================\n");
        $finish;
    end

endmodule
