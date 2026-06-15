// level_manager.sv — price level management, order matching, and pool operation dispatch

module level_manager
    import ob_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,
    input  order_msg_t   msg_in,
    input  logic         msg_valid,
    output logic         msg_ready,
    output pool_op_t     op_out,
    output logic         op_valid,
    input  logic         op_ready,
    input  pool_update_t pool_update,
    input  logic         pool_update_valid
);

    // Internal state machine enum
    typedef enum logic [2:0] {
        LM_READY          = 3'b000,
        LM_CANCEL_WAIT    = 3'b001,
        LM_L2_WAIT        = 3'b010,
        LM_L2_CANCEL_WAIT = 3'b011,
        LM_SLIDE          = 3'b100
    } lm_state_t;

    localparam int NUM_CHUNKS = L2_DEPTH / L1_DEPTH;
    localparam int CHUNK_IDX_WIDTH = $clog2(NUM_CHUNKS);
    localparam int L1_IDX_WIDTH = $clog2(L1_DEPTH);
    localparam int BURST_LEN_WIDTH = $clog2(L1_DEPTH) + 1;
    localparam int PL_BYTES       = $bits(price_level_t) / 8;
    localparam int HEAD_BYTE_MASK = (1 << (ORDER_ID_WIDTH/8)) - 1;  // head_order_id LSBs
    localparam logic [PL_BYTES-1:0] BE_HEAD = PL_BYTES'(HEAD_BYTE_MASK);
    localparam logic [PL_BYTES-1:0] BE_ALL  = '1;

    // =========================================================================
    // Section: Core State and Storage
    // =========================================================================
    lm_state_t                   state;
    price_level_t                l1_bid [0:L1_DEPTH-1];
    price_level_t                l1_ask [0:L1_DEPTH-1];
    logic [L1_DEPTH-1:0]         bid_bitmap;
    logic [L1_DEPTH-1:0]         ask_bitmap;
    logic [PRICE_WIDTH-1:0]      bid_head;
    logic [PRICE_WIDTH-1:0]      ask_head;
    logic                        bid_valid;
    logic                        ask_valid;
    logic [ORDER_ID_WIDTH-1:0]   cur_maker_id;
    logic [PRICE_WIDTH-1:0]      cancel_price;
    logic [QTY_WIDTH-1:0]        cancel_qty;
    order_msg_t                  cur_msg;
    logic [L1_IDX_WIDTH-1:0]     bid_l1_head_idx;  // array index of current best bid in circular buffer
    logic [L1_IDX_WIDTH-1:0]     ask_l1_head_idx;  // array index of current best ask in circular buffer
    logic [L1_IDX_WIDTH-1:0]     burst_fill_idx;   // current tail slot being filled
    side_t                       burst_fill_side;  // which side is being filled
    logic [L1_IDX_WIDTH-1:0]     slide_remaining;  // number of slots left to clear/fill during slide
    logic [L1_IDX_WIDTH-1:0]     slide_clear_idx;  // current slot index being cleared in circular buffer
    side_t                       slide_side;       // which side is sliding (BID or ASK)
    logic                        slide_from_l2;    // whether slide is fetching from L2
    logic [PRICE_WIDTH-1:0]      slide_l2_rd_addr; // L2 read address for slide fetch

    // L2 bitmap — unified across both sides, one bit per price level
    // Partitioned into L2_DEPTH/L1_DEPTH chunks of L1_DEPTH bits each
    // Single bit updates are one cycle — no read-modify-write needed
    logic [L1_DEPTH-1:0] l2_bitmap [0:NUM_CHUNKS-1];

    // =========================================================================
    // Section: HBM Interface and Instantiation
    // =========================================================================
    // Internal HBM Signals for L2
    // =========================================================================
    // Port A — burst read/write for L1 window slide
    logic                              l2_a_wr_valid;
    logic [PRICE_WIDTH-1:0]            l2_a_wr_addr;
    price_level_t                      l2_a_wr_data;
    logic [BURST_LEN_WIDTH-1:0]        l2_a_wr_len;
    logic                              l2_a_wr_ready;
    logic                              l2_a_rd_valid;
    logic [PRICE_WIDTH-1:0]            l2_a_rd_addr;
    logic [BURST_LEN_WIDTH-1:0]        l2_a_rd_len;
    price_level_t                      l2_a_rd_data;
    logic                              l2_a_rd_data_valid;
    logic                              l2_a_busy;

    // Port B — regular read + byte-enable write for MSG_ADD outside window
    logic                              l2_b_wr_valid;
    logic [PRICE_WIDTH-1:0]            l2_b_wr_addr;
    logic [PL_BYTES-1:0]               l2_b_wr_byte_en;
    price_level_t                      l2_b_wr_data;
    logic                              l2_b_rd_valid;
    logic [PRICE_WIDTH-1:0]            l2_b_rd_addr;
    price_level_t                      l2_b_rd_data;
    logic                              l2_b_rd_data_valid;
    logic                              l2_b_busy;

    // Port C — regular read + byte-enable write for pool update handling
    logic                              l2_c_wr_valid;
    logic [PRICE_WIDTH-1:0]            l2_c_wr_addr;
    logic [PL_BYTES-1:0]               l2_c_wr_byte_en;
    price_level_t                      l2_c_wr_data;
    logic                              l2_c_rd_valid;
    logic [PRICE_WIDTH-1:0]            l2_c_rd_addr;
    price_level_t                      l2_c_rd_data;
    logic                              l2_c_rd_data_valid;
    logic                              l2_c_busy;

    // =========================================================================
    // HBM model for L2
    // =========================================================================
    hbm_model #(
        .T           (price_level_t),
        .DEPTH       (L2_DEPTH),
        .MAX_BURST   (L1_DEPTH),
        .INIT_VALUE  (price_level_t'(total_qty: 0, tail_order_id: NULL_PTR, head_order_id: NULL_PTR))
    ) l2 (
        .clk              (clk),
        .rst_n            (rst_n),
        .a_wr_valid       (l2_a_wr_valid),
        .a_wr_addr        (l2_a_wr_addr),
        .a_wr_data        (l2_a_wr_data),
        .a_wr_len         (l2_a_wr_len),
        .a_wr_ready       (l2_a_wr_ready),
        .a_rd_valid       (l2_a_rd_valid),
        .a_rd_addr        (l2_a_rd_addr),
        .a_rd_len         (l2_a_rd_len),
        .a_rd_data        (l2_a_rd_data),
        .a_rd_data_valid  (l2_a_rd_data_valid),
        .a_busy           (l2_a_busy),
        .b_wr_valid       (l2_b_wr_valid),
        .b_wr_addr        (l2_b_wr_addr),
        .b_wr_byte_en     (l2_b_wr_byte_en),
        .b_wr_data        (l2_b_wr_data),
        .b_rd_valid       (l2_b_rd_valid),
        .b_rd_addr        (l2_b_rd_addr),
        .b_rd_data        (l2_b_rd_data),
        .b_rd_data_valid  (l2_b_rd_data_valid),
        .b_busy           (l2_b_busy),
        .c_wr_valid       (l2_c_wr_valid),
        .c_wr_addr        (l2_c_wr_addr),
        .c_wr_byte_en     (l2_c_wr_byte_en),
        .c_wr_data        (l2_c_wr_data),
        .c_rd_valid       (l2_c_rd_valid),
        .c_rd_addr        (l2_c_rd_addr),
        .c_rd_data        (l2_c_rd_data),
        .c_rd_data_valid  (l2_c_rd_data_valid),
        .c_busy           (l2_c_busy)
    );

    // =========================================================================
    // Section: Maker ID Logic
    // =========================================================================
    // Maker ID counter signals and logic
    // =========================================================================
    logic [ORDER_ID_WIDTH-1:0]   maker_counter;
    logic                        maker_counter_exhausted;

    // ID counter lifecycle for maker ID allocation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            maker_counter <= NULL_PTR + ORDER_ID_WIDTH'(1);
        end else if (!maker_counter_exhausted) begin // TODO: must be done when issuing OP_ADD/OP_ADD_FIRST
            maker_counter <= maker_counter + 1'b1;
        end
    end
    assign maker_counter_exhausted = maker_counter == NULL_PTR;

    // =========================================================================
    // Free-list signals and FIFO
    // =========================================================================
    logic [ORDER_ID_WIDTH-1:0]   free_list_din;
    logic                        free_list_push;
    logic                        free_list_full;
    logic [ORDER_ID_WIDTH-1:0]   free_list_dout;
    logic                        free_list_pop;
    logic                        free_list_empty;

    fifo #(
        .T    (logic [ORDER_ID_WIDTH-1:0]),
        .DEPTH(NUM_ORDERS)
    ) free_list (
        .clk  (clk),
        .rst_n(rst_n),
        .din  (free_list_din),
        .push (free_list_push),
        .full (free_list_full),
        .dout (free_list_dout),
        .pop  (free_list_pop),
        .empty(free_list_empty)
    );

    // =========================================================================
    // Free-list interaction
    // =========================================================================
    assign free_list_push = pool_update_valid && (pool_update.update_type == PU_FREE || pool_update.update_type == PU_BOTH);
    assign free_list_din  = pool_update.freed_order_id;
    assign free_list_pop  = (state == LM_READY) &&
                            msg_valid &&
                            (msg_in.msg_type == MSG_ADD) &&
                            maker_counter_exhausted; // TODO: must be popped when issuing OP_ADD/OP_ADD_FIRST

    // =========================================================================
    // Maker ID allocator
    // =========================================================================
    logic [ORDER_ID_WIDTH-1:0]   maker_id;
    logic                        maker_id_valid;
    always_comb begin
        if (!maker_counter_exhausted) begin
            maker_id = maker_counter;
        end else if (!free_list_empty) begin
            maker_id = free_list_dout;
        end else begin
            maker_id = NULL_PTR;
        end
    end
    assign maker_id_valid = maker_id != NULL_PTR;

    // =========================================================================
    // Section: Taker ID Logic
    // =========================================================================
    logic [ORDER_ID_WIDTH-1:0]   taker_id;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            taker_id <= '0;
        end else begin // TODO: must be done when issuing OP_MATCH/OP_MARKET_FAIL/OP_ADD_FAIL
            taker_id <= taker_id + 1'b1;
        end
    end

    // =========================================================================
    // Section: L1/L2 Search for the Next Best Price Level
    // =========================================================================
    // Circular L1 bitmap rotation
    // =========================================================================
    // Rotate bitmaps so bit 0 always corresponds to current best price
    logic [L1_DEPTH-1:0] bid_bitmap_rotated;
    logic [L1_DEPTH-1:0] ask_bitmap_rotated;

    assign bid_bitmap_rotated = (bid_bitmap >> bid_l1_head_idx) |
                                (bid_bitmap << (L1_DEPTH - bid_l1_head_idx));
    assign ask_bitmap_rotated = (ask_bitmap >> ask_l1_head_idx) |
                                (ask_bitmap << (L1_DEPTH - ask_l1_head_idx));

    // =========================================================================
    // Priority Encoder Logic for Next Best Price in L1
    // =========================================================================
    // Find first set bit in rotated bitmap (excluding bit 0 which is current best)
    // Result is the offset from current best to next best
    logic [L1_IDX_WIDTH-1:0] bid_l1_next_offset;
    logic [L1_IDX_WIDTH-1:0] ask_l1_next_offset;
    logic                    bid_l1_next_valid;
    logic                    ask_l1_next_valid;

    always_comb begin
        bid_l1_next_offset = '0;
        ask_l1_next_offset = '0;
        bid_l1_next_valid  = 1'b0;
        ask_l1_next_valid  = 1'b0;
        for (int i = L1_DEPTH-1; i > 0; i--) begin
            if (bid_bitmap_rotated[i]) begin
                bid_l1_next_offset = L1_IDX_WIDTH'(i);
                bid_l1_next_valid  = 1'b1;
            end
            if (ask_bitmap_rotated[i]) begin
                ask_l1_next_offset = L1_IDX_WIDTH'(i);
                ask_l1_next_valid  = 1'b1;
            end
        end
    end

    // =========================================================================
    // Priority Encoder Logic for Next Best Price in L2
    // =========================================================================
    // Coarse reduction — one bit per chunk, purely combinational
    logic [NUM_CHUNKS-1:0] l2_bitmap_coarse;
    always_comb begin
        for (int i = 0; i < NUM_CHUNKS; i++)
            l2_bitmap_coarse[i] = |l2_bitmap[i];
    end

    // Bid side L2 priority encoder signals
    logic [CHUNK_IDX_WIDTH-1:0] bid_l2_start_chunk;
    logic [CHUNK_IDX_WIDTH-1:0] bid_l2_coarse_idx;
    logic [L1_IDX_WIDTH-1:0]    bid_l2_fine_idx;
    logic [PRICE_WIDTH-1:0]     bid_l2_next_price;
    logic                       bid_l2_next_valid;

    // Ask side L2 priority encoder signals
    logic [CHUNK_IDX_WIDTH-1:0] ask_l2_start_chunk;
    logic [CHUNK_IDX_WIDTH-1:0] ask_l2_coarse_idx;
    logic [L1_IDX_WIDTH-1:0]    ask_l2_fine_idx;
    logic [PRICE_WIDTH-1:0]     ask_l2_next_price;
    logic                       ask_l2_next_valid;

    // Start chunk for L2 search — first chunk outside L1 window
    assign bid_l2_start_chunk = PRICE_WIDTH'(bid_head - L1_DEPTH) >> L1_IDX_WIDTH;
    assign ask_l2_start_chunk = PRICE_WIDTH'(ask_head + L1_DEPTH) >> L1_IDX_WIDTH;

    // Bid L2 coarse search — higher price wins
    always_comb begin
        bid_l2_coarse_idx = '0;
        bid_l2_next_valid = 1'b0;
        for (int i = 0; i < (L2_DEPTH/L1_DEPTH); i++) begin
            if (i <= int'(bid_l2_start_chunk) && l2_bitmap_coarse[i]) begin
                bid_l2_coarse_idx = CHUNK_IDX_WIDTH'(i);
                bid_l2_next_valid = 1'b1;
            end
        end
    end

    // Bid L2 fine search — higher bit index = higher price, search downward
    always_comb begin
        bid_l2_fine_idx   = '0;
        for (int i = 0; i < L1_DEPTH; i++) begin
            if (l2_bitmap[bid_l2_coarse_idx][i]) begin
                bid_l2_fine_idx   = L1_IDX_WIDTH'(i);
            end
        end
    end

    assign bid_l2_next_price = PRICE_WIDTH'((bid_l2_coarse_idx << L1_IDX_WIDTH) | bid_l2_fine_idx);

    // Ask L2 coarse search — lower price wins
    always_comb begin
        ask_l2_coarse_idx = '0;
        ask_l2_next_valid = 1'b0;
        for (int i = (L2_DEPTH/L1_DEPTH)-1; i >= 0; i--) begin
            if (i >= int'(ask_l2_start_chunk) && l2_bitmap_coarse[i]) begin
                ask_l2_coarse_idx = CHUNK_IDX_WIDTH'(i);
                ask_l2_next_valid = 1'b1;
            end
        end
    end

    // Ask L2 fine search — lower bit index = lower price, search upward
    always_comb begin
        ask_l2_fine_idx   = '0;
        for (int i = L1_DEPTH-1; i >= 0; i--) begin
            if (l2_bitmap[ask_l2_coarse_idx][i]) begin
                ask_l2_fine_idx   = L1_IDX_WIDTH'(i);
            end
        end
    end

    assign ask_l2_next_price = PRICE_WIDTH'((ask_l2_coarse_idx << L1_IDX_WIDTH) | ask_l2_fine_idx);

    // =========================================================================
    // Section: Logic to determine whether there is any valid signal for each side
    // =========================================================================
    // Just need to check whether the best price level is valid
    assign bid_valid = bid_bitmap[bid_l1_head_idx];
    assign ask_valid = ask_bitmap[ask_l1_head_idx];

    // =========================================================================
    // Section: Index Calculation for L1 Lookup
    // =========================================================================
    // Helper function
    // =========================================================================
    function automatic logic l1_lookup(
        input   logic [PRICE_WIDTH-1:0]  price,
        input   side_t                   side,
        output  logic [L1_IDX_WIDTH-1:0] array_idx
    );
        logic [PRICE_WIDTH-1:0] offset;
        if (side == SIDE_BID) begin
            assert final (price <= bid_head) else $fatal(1, "level_manager: bid price exceeds best bid");
            offset = bid_head - price;
            array_idx = (bid_l1_head_idx + offset) % L1_DEPTH;
        end else begin
            assert final (price >= ask_head) else $fatal(1, "level_manager: ask price below best ask");
            offset = price - ask_head;
            array_idx = (ask_l1_head_idx + offset) % L1_DEPTH;
        end
        return (offset < L1_DEPTH);
    endfunction

    // =========================================================================
    // Pool update decode: in-window check and circular index
    // =========================================================================
    logic                    pu_in_window;
    logic [L1_IDX_WIDTH-1:0] pu_idx;
    always_comb begin
        if (pool_update_valid)
            pu_in_window = l1_lookup(pool_update.price, pool_update.side, pu_idx);
        else begin
            pu_in_window = 1'b0;
            pu_idx = '0;
        end
    end

    // =========================================================================
    // Section: L1 Update Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bid_bitmap <= '0;
            ask_bitmap <= '0;
            for (int i = 0; i < L1_DEPTH; i++) begin
                l1_bid[i] <= '0;
                l1_ask[i] <= '0;
            end
        end else begin
            if (l2_a_rd_data_valid) begin
                // Refill L1 tail slots from L2 burst read response
                assert final (state == LM_SLIDE)
                    else $fatal(1, "level_manager: burst fill received in invalid state");
                unique case (burst_fill_side)
                    SIDE_BID: begin
                        l1_bid[burst_fill_idx] <= l2_a_rd_data;
                        bid_bitmap[burst_fill_idx] <= l2_a_rd_data.total_qty != 0;
                    end
                    SIDE_ASK: begin
                        l1_ask[burst_fill_idx] <= l2_a_rd_data;
                        ask_bitmap[burst_fill_idx] <= l2_a_rd_data.total_qty != 0;
                    end
                endcase
            end else if (state == LM_READY) begin
                // TODO: Handle MSG_ADD and MSG_MARKET within L1 window
            end

            if (pool_update_valid && pu_in_window) begin
                unique case (pool_update.update_type)
                    PU_CANCEL: begin
                        assert final (state == LM_CANCEL_WAIT)
                            else $fatal(1, "level_manager: PU_CANCEL received in invalid state");
                        unique case (pool_update.side)
                            SIDE_BID: begin
                                l1_bid[pu_idx].total_qty <= l1_bid[pu_idx].total_qty - pool_update.qty;
                                if (l1_bid[pu_idx].total_qty - pool_update.qty == 0) begin
                                    bid_bitmap[pu_idx] <= 1'b0;
                                    // TODO: handle potential slide if best level is depleted by cancel
                                end
                            end
                            SIDE_ASK: begin
                                l1_ask[pu_idx].total_qty <= l1_ask[pu_idx].total_qty - pool_update.qty;
                                if (l1_ask[pu_idx].total_qty - pool_update.qty == 0) begin
                                    ask_bitmap[pu_idx] <= 1'b0;
                                    // TODO: handle potential slide if best level is depleted by cancel
                                end
                            end
                        endcase
                    end
                    PU_FREE: // No L1 update needed for free — just returning maker ID to free list, which is handled separately
                    PU_HEAD, PU_BOTH: begin
                        assert final (state != LM_L2_CANCEL_WAIT)
                            else $fatal(1, "level_manager: PU_HEAD/PU_BOTH received in invalid state");
                        if (state == LM_SLIDE) begin
                            // TODO: handle this case separately
                        end else begin
                            unique case (pool_update.side)
                                SIDE_BID:
                                    l1_bid[pu_idx].head_order_id <= pool_update.head_order_id;
                                SIDE_ASK:
                                    l1_ask[pu_idx].head_order_id <= pool_update.head_order_id;
                            endcase
                        end
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // L2 burst read response handler (L1 refill path from Port A)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_fill_idx    <= '0;
            burst_fill_side   <= SIDE_BID;
        end else begin
            if (l2_a_rd_data_valid) begin
                assert final (state == LM_SLIDE)
                    else $fatal(1, "level_manager: burst fill received in invalid state");
                unique case (burst_fill_side)
                    SIDE_BID:
                        burst_fill_idx <= L1_IDX_WIDTH'((burst_fill_idx - 1) % L1_DEPTH);
                    SIDE_ASK:
                        burst_fill_idx <= L1_IDX_WIDTH'((burst_fill_idx + 1) % L1_DEPTH);
                endcase
            end else begin
                // TODO: complete this section.
                // Set burst_fill_idx and burst_fill_side when slide begins from L2
                if (bid_slide_needed && bid_l1_next_valid) begin
                    burst_fill_idx    <= L1_IDX_WIDTH'((bid_l1_head_idx + bid_l1_next_offset - 1) % L1_DEPTH);
                    burst_fill_side   <= SIDE_BID;
                end
                if (ask_slide_needed && ask_l1_next_valid) begin
                    burst_fill_idx    <= ask_l1_head_idx;
                    burst_fill_side   <= SIDE_ASK;
                end
            end
        end
    end

    // =========================================================================
    // Section: Writes to L2 Port A
    // =========================================================================
    // Port A command driving (slide fetch + post-slide burst fetch)
    // =========================================================================
    always_comb begin
        l2_a_wr_valid = 1'b0;
        l2_a_wr_addr  = '0;
        l2_a_wr_data  = '0;
        l2_a_wr_len   = '0;
        l2_a_rd_valid = 1'b0;
        l2_a_rd_addr  = '0;
        l2_a_rd_len   = '0;

        if (state == LM_SLIDE && slide_from_l2) begin
            l2_a_rd_valid = 1'b1;
            l2_a_rd_addr  = slide_l2_rd_addr;
            l2_a_rd_len   = ($clog2(L1_DEPTH)+1)'(L1_DEPTH);
        end

        // Preserve original priority: these assignments come after LM_SLIDE handling.
        if (bid_slide_needed) begin
            l2_a_rd_valid = 1'b1;
            l2_a_rd_addr  = PRICE_WIDTH'(bid_head - (L1_DEPTH - 1));
            l2_a_rd_len   = ($clog2(L1_DEPTH)+1)'(bid_l1_next_offset);
        end
        if (ask_slide_needed) begin
            l2_a_rd_valid = 1'b1;
            l2_a_rd_addr  = PRICE_WIDTH'(ask_head + L1_DEPTH - ask_l1_next_offset);
            l2_a_rd_len   = ($clog2(L1_DEPTH)+1)'(ask_l1_next_offset);
        end
    end

    // =========================================================================
    // Section: Writes to L2 Port B
    // =========================================================================
    // Port B command driving (MSG_ADD outside window)
    // =========================================================================
    always_comb begin
        l2_b_wr_valid   = 1'b0;
        l2_b_wr_addr    = '0;
        l2_b_wr_byte_en = '0;
        l2_b_wr_data    = '0;
        l2_b_rd_valid   = 1'b0;
        l2_b_rd_addr    = '0;

        case (state)
            LM_READY: begin
                if (msg_valid && msg_in.msg_type == MSG_ADD) begin
                    logic [PRICE_WIDTH-1:0] idx;
                    if (!l1_lookup(msg_in.price, msg_in.side, idx)) begin
                        l2_b_rd_valid = 1'b1;
                        l2_b_rd_addr  = msg_in.price;
                    end
                end
            end

            LM_L2_WAIT: begin
                if (l2_b_rd_data_valid) begin
                    l2_b_wr_valid   = 1'b1;
                    l2_b_wr_addr    = cur_msg.price;
                    l2_b_wr_byte_en = BE_ALL & ~BE_HEAD; // all bytes except head_order_id
                    l2_b_wr_data    = '{
                        total_qty     : l2_b_rd_data.total_qty + cur_msg.qty,
                        tail_order_id : cur_maker_id,  // new tail
                        head_order_id : l2_b_rd_data.head_order_id  // preserved
                    };
                end
            end

            default: ;
        endcase
    end

    // =========================================================================
    // Section: Writes to L2 Port C
    // =========================================================================
    // Port C command driving (cancel path + pool update head writes)
    // =========================================================================
    always_comb begin
        l2_c_wr_valid   = 1'b0;
        l2_c_wr_addr    = '0;
        l2_c_wr_byte_en = '0;
        l2_c_wr_data    = '0;
        l2_c_rd_valid   = 1'b0;
        l2_c_rd_addr    = '0;

        case (state)
            LM_CANCEL_WAIT: begin
                if (pool_update_valid && pool_update.update_type == PU_CANCEL) begin
                    logic [PRICE_WIDTH-1:0] idx;
                    if (!l1_lookup(pool_update.price, pool_update.side, idx)) begin
                        l2_c_rd_valid = 1'b1;
                        l2_c_rd_addr  = pool_update.price;
                    end
                end
            end

            LM_L2_CANCEL_WAIT: begin
                if (l2_c_rd_data_valid) begin
                    l2_c_wr_valid   = 1'b1;
                    l2_c_wr_addr    = cancel_price;
                    l2_c_wr_byte_en = BE_ALL;
                    l2_c_wr_data    = '{
                        total_qty     : l2_c_rd_data.total_qty - cancel_qty,
                        tail_order_id : l2_c_rd_data.tail_order_id,
                        head_order_id : l2_c_rd_data.head_order_id
                    };
                end
            end

            default: ;
        endcase

        // Preserve original override behavior for PU_HEAD/PU_BOTH outside L1 window.
        if (pool_update_valid) begin
            logic [PRICE_WIDTH-1:0] pu_idx_local;
            if ((pool_update.update_type == PU_HEAD || pool_update.update_type == PU_BOTH) &&
                !l1_lookup(pool_update.price, pool_update.side, pu_idx_local)) begin
                l2_c_wr_valid   = 1'b1;
                l2_c_wr_addr    = pool_update.price;
                l2_c_wr_byte_en = BE_HEAD;
                l2_c_wr_data    = '{default:'0, head_order_id: pool_update.head_order_id};
            end
        end
    end

    // =========================================================================
    // Section: Control FSM
    // =========================================================================
    // State machine and registered control/state
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LM_READY;
            cur_msg <= '0;
            cur_maker_id <= '0;
            cancel_price <= '0;
            cancel_qty <= '0;
            bid_l1_head_idx <= '0;
            ask_l1_head_idx <= '0;
            bid_head <= '0;
            ask_head <= '0;
            slide_remaining <= '0;
            slide_clear_idx <= '0;
            slide_side <= SIDE_BID;
            slide_from_l2 <= 1'b0;
            slide_l2_rd_addr <= '0;
            for (int i = 0; i < (L2_DEPTH/L1_DEPTH); i++)
                l2_bitmap[i] <= '0;
        end else begin
            case (state)
                LM_READY: begin
                    if (msg_valid) begin
                        cur_msg <= msg_in;
                        if (msg_in.msg_type == MSG_ADD && maker_id_valid)
                            cur_maker_id <= maker_id;
                        case (msg_in.msg_type)
                            MSG_ADD: begin
                                $display("level_manager: received MSG_ADD");
                                // Stub for ADD handling
                            end
                            MSG_CANCEL: begin
                                $display("level_manager: received MSG_CANCEL");
                                state <= LM_CANCEL_WAIT;
                            end
                            MSG_MARKET: begin
                                $display("level_manager: received MSG_MARKET");
                                // Stub for MARKET handling
                            end
                            default: begin
                                // Invalid message type
                            end
                        endcase
                    end
                    if (msg_valid && msg_in.msg_type == MSG_ADD) begin
                        logic [PRICE_WIDTH-1:0] idx;
                        if (!l1_lookup(msg_in.price, msg_in.side, idx))
                            state <= LM_L2_WAIT;  // stall for L2 read
                    end

                    // Slide trigger when best level is depleted
                    if (bid_slide_needed) begin
                        slide_side <= SIDE_BID;
                        state <= LM_SLIDE;
                        if (bid_l1_next_valid) begin
                            slide_remaining <= bid_l1_next_offset;
                            slide_clear_idx <= bid_l1_head_idx;
                            slide_from_l2 <= 1'b0;
                            bid_head <= bid_head - PRICE_WIDTH'(bid_l1_next_offset);
                            bid_l1_head_idx <= L1_IDX_WIDTH'((bid_l1_head_idx + bid_l1_next_offset) % L1_DEPTH);
                            slide_l2_rd_addr <= '0;
                        end else begin
                            automatic logic [PRICE_WIDTH-1:0] k = bid_head - bid_l2_next_price;
                            slide_remaining <= L1_IDX_WIDTH'(k > L1_DEPTH ? L1_DEPTH : k);
                            slide_clear_idx <= bid_l1_head_idx;
                            slide_from_l2 <= 1'b1;
                            bid_head <= bid_l2_next_price;
                            bid_l1_head_idx <= L1_IDX_WIDTH'((bid_l1_head_idx + (k % L1_DEPTH)) % L1_DEPTH);
                            slide_l2_rd_addr <= PRICE_WIDTH'(bid_l2_next_price - (L1_DEPTH - 1));
                        end
                    end else if (ask_slide_needed) begin
                        slide_side <= SIDE_ASK;
                        state <= LM_SLIDE;
                        if (ask_l1_next_valid) begin
                            slide_remaining <= ask_l1_next_offset;
                            slide_clear_idx <= ask_l1_head_idx;
                            slide_from_l2 <= 1'b0;
                            ask_head <= ask_head + PRICE_WIDTH'(ask_l1_next_offset);
                            ask_l1_head_idx <= L1_IDX_WIDTH'((ask_l1_head_idx + ask_l1_next_offset) % L1_DEPTH);
                            slide_l2_rd_addr <= '0;
                        end else begin
                            automatic logic [PRICE_WIDTH-1:0] k = ask_l2_next_price - ask_head;
                            slide_remaining <= L1_IDX_WIDTH'(k > L1_DEPTH ? L1_DEPTH : k);
                            slide_clear_idx <= ask_l1_head_idx;
                            slide_from_l2 <= 1'b1;
                            ask_head <= ask_l2_next_price;
                            ask_l1_head_idx <= L1_IDX_WIDTH'((ask_l1_head_idx + (k % L1_DEPTH)) % L1_DEPTH);
                            slide_l2_rd_addr <= PRICE_WIDTH'(ask_l2_next_price);
                        end
                    end
                end

                LM_SLIDE: begin
                    // Clear one slot per cycle
                    if (slide_side == SIDE_BID) begin
                        automatic logic [PRICE_WIDTH-1:0] clearing_price =
                            PRICE_WIDTH'(bid_head + slide_remaining);
                        l2_bitmap[clearing_price >> L1_IDX_WIDTH]
                                 [clearing_price[L1_IDX_WIDTH-1:0]] <= 1'b0;
                    end else begin
                        automatic logic [PRICE_WIDTH-1:0] clearing_price =
                            PRICE_WIDTH'(ask_head - slide_remaining);
                        l2_bitmap[clearing_price >> L1_IDX_WIDTH]
                                 [clearing_price[L1_IDX_WIDTH-1:0]] <= 1'b0;
                    end
                    slide_clear_idx <= L1_IDX_WIDTH'((slide_clear_idx + 1) % L1_DEPTH);
                    slide_remaining <= slide_remaining - 1;
                    if (slide_remaining == 1)
                        state <= LM_READY;
                end

                LM_CANCEL_WAIT: begin
                    // Waiting for pool_update handler to return to READY
                    if (pool_update_valid && pool_update.update_type == PU_CANCEL) begin
                        cancel_price <= pool_update.price;
                        cancel_qty <= pool_update.qty;
                        logic [PRICE_WIDTH-1:0] idx;
                        if (l1_lookup(pool_update.price, pool_update.side, idx))
                            state <= LM_READY;   // in window — L1 update, no L2 read needed
                        else
                            state <= LM_L2_CANCEL_WAIT;  // outside window — need L2 read
                    end
                end

                LM_L2_WAIT: begin
                    // Waiting for l2_b_rd_data_valid
                    if (l2_b_rd_data_valid) begin
                        state <= LM_READY;
                    end
                end

                LM_L2_CANCEL_WAIT: begin
                    // Waiting for l2_c_rd_data_valid
                    if (l2_c_rd_data_valid) begin
                        state <= LM_READY;
                    end
                end

                default: begin
                    state <= LM_READY;
                end
            endcase
        end
    end

    // =========================================================================
    // Section: Outputs
    // =========================================================================
    always_comb begin
        // Default assignments
        msg_ready = 1'b0;
        op_valid = 1'b0;
        op_out = '0;

        case (state)
            LM_READY: begin
                msg_ready = 1'b1;
            end

            LM_CANCEL_WAIT: begin
                msg_ready = 1'b0;
            end

            LM_L2_WAIT: begin
                msg_ready = 1'b0;
            end

            LM_SLIDE: begin
                msg_ready = 1'b0;
            end

            default: begin
                msg_ready = 1'b0;
            end
        endcase
    end

endmodule
