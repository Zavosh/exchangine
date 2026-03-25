// ob_pkg.sv — shared types and parameters for Exchangine

package ob_pkg;

   // Book configuration parameters
   parameter int NUM_ORDERS = 64;         // total resting order slots across all levels
   parameter int PRICE_WIDTH = 16;        // bits for price, fixed-point in cents
   parameter int QTY_WIDTH = 16;          // bits for quantity
   parameter int L1_DEPTH = 64;           // number of price level slots in L1 register array per side
   parameter int OP_BUFFER_DEPTH = 8;     // depth of the unified operation buffer between level_manager and order_pool

   localparam int ORDER_ID_WIDTH = $clog2(NUM_ORDERS);     // bits for order ID
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

   // One resting order in L3; indexed by order_id (order_id and price not in struct)
   typedef struct packed {
      logic                        valid;
      logic [QTY_WIDTH-1:0]        qty;
      logic [ORDER_ID_WIDTH-1:0]   next_order_id;
   } resting_order_t;

   // Operation types issued by level_manager to order_pool via the operation buffer
   typedef enum logic [1:0] {
      OP_ADD    = 2'b00,
      OP_MATCH  = 2'b01,
      OP_CANCEL = 2'b10
   } op_type_t;

   // Operation envelope for level_manager to order_pool interaction
   typedef struct packed {
      op_type_t                    op_type;
      logic [ORDER_ID_WIDTH-1:0]   order_id;            // OP_ADD: new slot index; OP_CANCEL: slot to zero; OP_MATCH: taker_id
      logic [QTY_WIDTH-1:0]        qty;                 // OP_ADD: qty of new order; OP_MATCH: incoming qty; OP_CANCEL: don't-care
      logic [ORDER_ID_WIDTH-1:0]   list_ptr;            // OP_ADD: tail slot (self-pointer if empty); OP_MATCH: head slot to walk; OP_CANCEL: don't-care
      logic [PRICE_WIDTH-1:0]      fill_price;          // OP_MATCH only: fill price; don't-care for others
      side_t                       maker_side;          // OP_MATCH only: maker side for execution_t; don't-care for others
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
   } ack_t;

endpackage
