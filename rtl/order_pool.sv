// order_pool.sv — resting order pool with BRAM backing and operation state machine

module order_pool
    import ob_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    // Operation input — standard valid/ready handshake
    input  pool_op_t                op_in,
    input  logic                    op_valid,
    output logic                    op_ready,
    // Writeback to level_manager
    output pool_update_t            pool_update,
    output logic                    pool_update_valid,
    // Execution output
    output execution_t              exec_out,
    output logic                    exec_valid,
    // Ack output
    output ack_t                    ack_out,
    output logic                    ack_valid
);

    // Internal localparams for Port B byte-enable masks
    localparam int NUM_BYTES  = $bits(resting_order_t) / 8;
    localparam logic [NUM_BYTES-1:0] BE_NEXT_ID =
        NUM_BYTES'((1 << (ORDER_ID_WIDTH/8)) - 1);
    localparam logic [NUM_BYTES-1:0] BE_ALL = '1;

    // Internal state
    typedef enum logic [1:0] {
        IDLE        = 2'b00,
        CANCEL_EXEC = 2'b01,
        MATCH_EXEC  = 2'b10
    } op_state_t;

    op_state_t                   state, nc_state;
    pool_op_t                    cur_op, nc_cur_op;
    logic [ORDER_ID_WIDTH-1:0]   cur_order_id, nc_cur_order_id;
    logic [QTY_WIDTH-1:0]        remaining_qty, nc_remaining_qty;
    logic [QTY_WIDTH-1:0]        fill_qty;

    // BRAM interface signals (internal, connecting to bram_model instance)
    logic                       a_valid;
    logic                       a_wr_en;
    logic [ORDER_ID_WIDTH-1:0]  a_addr;
    resting_order_t             a_wr_data;
    resting_order_t             a_rd_data;
    logic                       a_rd_data_valid;
    logic                       b_valid;
    logic [ORDER_ID_WIDTH-1:0]  b_addr;
    logic [NUM_BYTES-1:0]       b_wr_byte_en;
    resting_order_t             b_wr_data;

    // Instantiate bram_model
    bram_model #(
        .T           (resting_order_t),
        .DEPTH       (NUM_ORDERS),
        .READ_LATENCY(1)
    ) u_pool (
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

    // State machine and registered signals
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            state <= IDLE;
            cur_op <= '0;
            remaining_qty <= '0;
            cur_order_id <= '0;
        end else begin
            state <= nc_state;
            cur_op <= nc_cur_op;
            remaining_qty <= nc_remaining_qty;
            cur_order_id <= nc_cur_order_id;
        end

    assign fill_qty = (remaining_qty < a_rd_data.qty) ? remaining_qty : a_rd_data.qty;
    assign op_ready = (state == IDLE);

    // Output logic and BRAM signal assignments
    always_comb begin
        // Default all outputs and BRAM signals to 0
        pool_update = '0;
        pool_update_valid = 1'b0;
        exec_out = '0;
        exec_valid = 1'b0;
        ack_out = '0;
        ack_valid = 1'b0;
        a_valid = 1'b0;
        a_wr_en = 1'b0;
        a_addr = '0;
        a_wr_data = '0;
        b_valid = 1'b0;
        b_addr = '0;
        b_wr_byte_en = '0;
        b_wr_data = '0;

        // Default next cycle values
        nc_state = state;
        nc_cur_op = cur_op;
        nc_cur_order_id = cur_order_id;
        nc_remaining_qty = remaining_qty;

        unique case (state)
            IDLE: begin
                assert final (!a_rd_data_valid)
                    else $fatal(1, "order_pool: unexpected a_rd_data_valid in IDLE state");
                if (op_valid) begin
                    nc_cur_op = op_in;
                    unique case (op_in.op_type)
                        OP_ADD: begin
                            // Port A write
                            a_valid = 1'b1;
                            a_wr_en = 1'b1;
                            a_addr = op_in.order_id;
                            a_wr_data = '{valid:1'b1, side:op_in.maker_side, price:op_in.fill_price, qty:op_in.qty, next_order_id:op_in.order_id, default:'0};
                            // Port B write
                            b_valid = 1'b1;
                            b_addr = op_in.list_ptr;
                            b_wr_byte_en = BE_NEXT_ID;
                            b_wr_data.next_order_id = op_in.order_id;
                            // Emit ack
                            ack_valid = 1'b1;
                            ack_out = '{order_id:op_in.order_id, accepted:1'b1, msg_type:MSG_ADD, remaining_qty:op_in.qty};
                        end
                        OP_ADD_FAIL: begin
                            // Emit ack
                            ack_valid = 1'b1;
                            ack_out = '{order_id:op_in.order_id, accepted:1'b0, msg_type:MSG_ADD, remaining_qty:op_in.qty};
                        end
                        OP_CANCEL: begin
                            // Port A read
                            a_valid = 1'b1;
                            a_wr_en = 1'b0;
                            a_addr = op_in.order_id;
                            nc_state = CANCEL_EXEC;
                        end
                        OP_MATCH: begin
                            // Port A read
                            a_valid = 1'b1;
                            a_wr_en = 1'b0;
                            a_addr = op_in.list_ptr;
                            nc_cur_order_id = op_in.list_ptr;
                            nc_remaining_qty = op_in.qty;
                            nc_state = MATCH_EXEC;
                        end
                        OP_MARKET_FAIL: begin
                            // Emit ack
                            ack_valid = 1'b1;
                            ack_out = '{order_id:op_in.order_id, accepted:1'b0, msg_type:MSG_MARKET, remaining_qty:op_in.qty};
                        end
                    endcase
                end
            end
            CANCEL_EXEC:
                if (a_rd_data_valid) begin
                    if (a_rd_data.valid && a_rd_data.qty != 0) begin
                        // Port A write
                        a_valid = 1'b1;
                        a_wr_en = 1'b1;
                        a_addr = cur_op.order_id;
                        a_wr_data = a_rd_data;
                        a_wr_data.qty = '0;
                        // Emit pool_update
                        pool_update_valid = 1'b1;
                        pool_update = '{is_cancel:1'b1, price:a_rd_data.price, side:a_rd_data.side, qty:a_rd_data.qty, default:'0};
                        // Emit ack
                        ack_valid = 1'b1;
                        ack_out = '{order_id:cur_op.order_id, accepted:1'b1, msg_type:MSG_CANCEL, remaining_qty:a_rd_data.qty};
                    end else begin
                        // Emit pool_update
                        pool_update_valid = 1'b1;
                        pool_update.is_cancel = 1'b1;
                        pool_update.qty = '0;
                        // Emit ack
                        ack_valid = 1'b1;
                        ack_out = '{order_id:cur_op.order_id, accepted:1'b0, msg_type:MSG_CANCEL, remaining_qty:'0};
                    end
                    nc_state = IDLE;
                end
            MATCH_EXEC: begin
                assert final (remaining_qty != 0)
                    else $fatal(1, "order_pool: MATCH_EXEC entered with remaining_qty=0");
                if (a_rd_data_valid) begin
                    if (a_rd_data.valid) begin
                        if (a_rd_data.qty != 0) begin
                            // Emit exec_out
                            exec_valid = 1'b1;
                            exec_out = '{maker_id:cur_order_id, taker_id:cur_op.order_id, fill_qty:fill_qty, fill_price:cur_op.fill_price, maker_side:cur_op.maker_side};
                            nc_remaining_qty = remaining_qty - fill_qty;
                        end
                        if (a_rd_data.qty == fill_qty) begin // includes case where a_rd_data.qty == 0
                            // Port B write to invalidate, emit pool_update
                            b_valid = 1'b1;
                            b_addr = cur_order_id;
                            b_wr_byte_en = BE_ALL;
                            b_wr_data = a_rd_data;
                            b_wr_data.valid = 1'b0;
                            pool_update_valid = 1'b1;
                            pool_update = '{is_cancel:1'b0, price:a_rd_data.price, side:a_rd_data.side, head_order_id:a_rd_data.next_order_id, freed_order_id:cur_order_id, default:'0};
                            assert final (a_rd_data.next_order_id != cur_order_id || remaining_qty == fill_qty)
                                else $fatal(1, "order_pool: tail consumed with remaining_qty > 0 — level_manager total_qty inconsistency");
                        end
                        if (remaining_qty == fill_qty) begin
                            if (a_rd_data.qty != fill_qty) begin
                                // Port B write to decrement qty
                                b_valid = 1'b1;
                                b_addr = cur_order_id;
                                b_wr_byte_en = BE_ALL;
                                b_wr_data = a_rd_data;
                                b_wr_data.qty = a_rd_data.qty - fill_qty;
                            end
                            nc_state = IDLE;
                        end
                    end
                    if (!a_rd_data.valid || (a_rd_data.qty == fill_qty && remaining_qty != fill_qty)) begin // includes case where a_rd_data.qty == 0
                        // Port A read next
                        a_valid = 1'b1;
                        a_wr_en = 1'b0;
                        a_addr = a_rd_data.next_order_id;
                        nc_cur_order_id = a_rd_data.next_order_id;
                    end
                end
            end
        endcase
    end

endmodule
