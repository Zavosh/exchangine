module order_book;

   // Enforce byte-alignment requirement for Port B byte-enable writes on the next_order_id field
   // of resting_order_t. Port B requires ORDER_ID_WIDTH to be a multiple of 8 bits.
   initial assert (ob_pkg::ORDER_ID_WIDTH % 8 == 0)
      else $fatal(1, "ob_pkg: ORDER_ID_WIDTH must be a multiple of 8 for byte-enable writes on next_order_id");

endmodule
