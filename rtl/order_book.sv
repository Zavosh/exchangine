module order_book;

    // Enforce byte-alignment requirement for Port B byte-enable writes on the next_order_id field
    // of resting_order_t. Port B requires ORDER_ID_WIDTH to be a multiple of 8 bits.
    initial begin
        assert (ob_pkg::ORDER_ID_WIDTH % 8 == 0)
            else $fatal(1, "ob_pkg: ORDER_ID_WIDTH must be a multiple of 8 for byte-enable writes on next_order_id");
        assert (ob_pkg::RESTING_ORDER_PAD != 0)
            // $fatal(1, "ob_pkg: Comment out this line and uncomment next line and the _pad field in resting_order_t since padding is needed for byte alignment");
            else $fatal(1, "ob_pkg: Uncomment previous line and comment out this line and the _pad field in resting_order_t since no padding is needed for byte alignment");
        assert ($bits(ob_pkg::price_level_t) % 8 == 0) // TEMPORARY: I need to add padding to a price_level_t wrapper to make it power of 2 bytes for L2.
            else $fatal(1, "ob_pkg: price_level_t must be byte-aligned for Port B and C byte-enabled burst writes");
    end

endmodule
