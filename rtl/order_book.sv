module order_book;

    // Enforce byte-alignment requirement for Port B byte-enable writes on the next_order_id field
    // of resting_order_t. Port B requires ORDER_ID_WIDTH to be a multiple of 8 bits.
    initial begin
        assert (ob_pkg::ORDER_ID_WIDTH % 8 == 0)
            else $fatal(1, "ob_pkg: ORDER_ID_WIDTH must be a multiple of 8 for byte-enable writes on next_order_id");
        assert (ob_pkg::RESTING_ORDER_PAD != 0)
            // $fatal(1, "ob_pkg: Comment out this line and uncomment next line and the _pad field in resting_order_t since padding is needed for byte alignment");
            else $fatal(1, "ob_pkg: Uncomment previous line and comment out this line and the _pad field in resting_order_t since no padding is needed for byte alignment");
    end

endmodule
