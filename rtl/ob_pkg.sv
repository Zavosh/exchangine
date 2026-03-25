// ob_pkg.sv — shared types and parameters for Exchangine

package ob_pkg;

   // Book configuration parameters
   parameter int NUM_PRICE_LEVELS = 8;    // price levels per side
   parameter int NUM_ORDERS = 64;         // total resting order slots across all levels
   parameter int PRICE_WIDTH = 16;        // bits for price, fixed-point in cents
   parameter int QTY_WIDTH = 16;          // bits for quantity

   localparam int ORDER_ID_WIDTH = $clog2(NUM_ORDERS);     // bits for order ID

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
      logic                        valid;
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

   // Maker-taker fill event (execution report)
   typedef struct packed {
      logic                        valid;
      logic [ORDER_ID_WIDTH-1:0]   maker_id;
      logic [ORDER_ID_WIDTH-1:0]   taker_id;
      logic [QTY_WIDTH-1:0]        fill_qty;
      logic [PRICE_WIDTH-1:0]      fill_price;
   } execution_t;

   // Acknowledgement to order submitter for acceptance/rejection
   typedef struct packed {
      logic                        valid;
      logic [ORDER_ID_WIDTH-1:0]   order_id;
      logic                        accepted;
      msg_type_t                   msg_type;
   } ack_t;

endpackage
