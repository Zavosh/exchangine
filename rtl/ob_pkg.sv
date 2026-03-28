// ob_pkg.sv — shared types and parameters for Exchangine

package ob_pkg;

   // Book configuration parameters
   parameter int ORDER_ID_WIDTH = 8;      // bits for order ID (needs to be multiple of 8)
   parameter int PRICE_WIDTH = 16;        // bits for price, fixed-point in cents
   parameter int QTY_WIDTH = 16;          // bits for quantity
   parameter int L1_DEPTH = 64;           // number of price level slots in L1 register array per side
   parameter int OP_BUFFER_DEPTH = 8;     // depth of the unified operation buffer between level_manager and order_pool

   localparam int NUM_ORDERS = 2 ** ORDER_ID_WIDTH;       // total resting order slots across all levels
   localparam int L2_DEPTH = 2 ** PRICE_WIDTH;            // number of possible price levels (2^PRICE_WIDTH)

   // Message type (add/cancel/market) for incoming order requests
   typedef enum logic [1:0] {
      MSG_ADD    = 2'b00,
      MSG_CANCEL = 2'b01,
      MSG_MARKET = 2'b10
   } msg_type_t;

   // Side of the market for orders
   typedef enum logic {
      SIDE_BID = 1'b0,
      SIDE_ASK = 1'b1
   } side_t;

   // Incoming order message payload
   // price is don't-care for CANCEL and MARKET
   // qty is don't-care for CANCEL
   // order_id is don't-care for ADD and MARKET
   typedef struct packed {
      msg_type_t                   msg_type;
      side_t                       side;
      logic [PRICE_WIDTH-1:0]      price;
      logic [QTY_WIDTH-1:0]        qty;
      logic [ORDER_ID_WIDTH-1:0]   order_id;
   } order_msg_t;

   // One price level in L1/L2; indexed by price index (price value not in struct)
   typedef struct packed {
      logic                        valid;
      logic [QTY_WIDTH-1:0]        total_qty;
      logic [ORDER_ID_WIDTH-1:0]   head_order_id;
      logic [ORDER_ID_WIDTH-1:0]   tail_order_id;
   } price_level_t;

   // One resting order in L3; indexed by order_id. (order_id not in struct)
   // next_order_id is placed at the LSBs deliberately so Port B of the dual-port
   // BRAM can update it independently using a fixed byte-enable mask of
   // ORDER_ID_WIDTH/8 least significant bytes.
   localparam int RESTING_ORDER_BITS_RAW = 1 + $bits(side_t) + PRICE_WIDTH + QTY_WIDTH + ORDER_ID_WIDTH; // Modify as needed when fields are added/removed!
   localparam int RESTING_ORDER_BYTES    = (RESTING_ORDER_BITS_RAW + 7) / 8;
   localparam int RESTING_ORDER_PAD      = RESTING_ORDER_BYTES * 8 - RESTING_ORDER_BITS_RAW;
   typedef struct packed {
      // Modify RESTING_ORDER_BITS_RAW when fields are added/removed from this struct!!!
      // COMMENT NEXT LINE IFF RESTING_ORDER_PAD == 0 !!!
      logic [RESTING_ORDER_PAD-1:0]_pad;          // MSBs — padding for byte alignment
      logic                        valid;
      side_t                       side;
      logic [PRICE_WIDTH-1:0]      price;
      logic [QTY_WIDTH-1:0]        qty;
      logic [ORDER_ID_WIDTH-1:0]   next_order_id; // LSBs — target of Port B byte-enable writes
   } resting_order_t;

   // pool_update_t — writeback from order_pool to level_manager
   // Emitted once per slot invalidation (valid=0 write) during match walk, and once per cancel completion.
   // level_manager uses price and side to locate the L1/L2 entry, then branches on is_cancel to determine
   // what to update. On is_cancel=1, level_manager decrements total_qty at the price level by qty.
   // On iscancel=0, level_manager pushes freed_order_id to free list.
   // level_manager updates head pointer only when head_order_id != freed_order_id.
   // When head_order_id == freed_order_id: level depleted — skip head update to avoid
   // overwriting a concurrent ADD that may have already set a fresh head pointer.
   typedef struct packed {
      logic                      is_cancel;      // 1=cancel completion, 0=match walk step
      logic [PRICE_WIDTH-1:0]    price;          // price level to update in L1/L2
      side_t                     side;           // which side of the book
      logic [ORDER_ID_WIDTH-1:0] head_order_id;  // new head — equals freed_order_id if level depleted
      logic [ORDER_ID_WIDTH-1:0] freed_order_id; // slot just set to valid=0 — push to free list
      logic [QTY_WIDTH-1:0]      qty;            // qty at cancel time — used when is_cancel=1 only
   } pool_update_t;

   // Operation types issued by level_manager to order_pool via the operation buffer
   typedef enum logic [2:0] {
      OP_ADD         = 3'b000,  // add resting order to pool
      OP_MATCH       = 3'b001,  // match incoming order against resting orders
      OP_CANCEL      = 3'b010,  // cancel resting order by zeroing qty
      OP_MARKET_FAIL = 3'b011,  // MSG_MARKET exhausted book with remaining qty
      OP_ADD_FAIL    = 3'b100   // ADD rejected — free list empty (book full)
   } op_type_t;

   // Operation envelope for level_manager to order_pool interaction
   typedef struct packed {
      op_type_t                    op_type;
      logic [ORDER_ID_WIDTH-1:0]   order_id;            // OP_ADD: new slot index; OP_CANCEL: slot to zero; OP_MATCH: taker_id; OP_MARKET_FAIL: don't-care
      logic [QTY_WIDTH-1:0]        qty;                 // OP_ADD: qty of new order; OP_MATCH: incoming qty; OP_CANCEL: don't-care; OP_MARKET_FAIL: wasted remainder
      logic [ORDER_ID_WIDTH-1:0]   list_ptr;            // OP_ADD: tail slot (self-pointer if FIFO is empty); OP_MATCH: head slot to walk; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
      logic [PRICE_WIDTH-1:0]      fill_price;          // OP_ADD: price of new order; OP_MATCH: fill price; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
      side_t                       maker_side;          // OP_ADD: side of new order; OP_MATCH: maker side for execution_t; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
   } pool_op_t;

   // Maker-taker fill event (execution report)
   typedef struct packed {
      logic [ORDER_ID_WIDTH-1:0]   maker_id;
      logic [ORDER_ID_WIDTH-1:0]   taker_id;
      logic [QTY_WIDTH-1:0]        fill_qty;
      logic [PRICE_WIDTH-1:0]      fill_price;
      side_t                       maker_side;
   } execution_t;

   // Acknowledgement to order submitter for acceptance/rejection
   typedef struct packed {
      logic [ORDER_ID_WIDTH-1:0]   order_id;
      logic                        accepted;
      msg_type_t                   msg_type;
      logic [QTY_WIDTH-1:0]        remaining_qty; // MSG_ADD: resting qty, MSG_CANCEL: qty at cancel time, MSG_MARKET: wasted remainder
   } ack_t;

endpackage
