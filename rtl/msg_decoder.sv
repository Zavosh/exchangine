// msg_decoder.sv — combinational AXI-Stream word to order_msg_t

module msg_decoder 
    import ob_pkg::*;
(
    input  logic [63:0]        s_axis_tdata,
    input  logic               s_axis_tvalid,
    output logic               s_axis_tready,
    output order_msg_t         msg_out,
    output logic               msg_valid,
    input  logic               msg_ready
);

   // Decode the MSBs of the incoming AXI-Stream word into an order_msg_t struct
   assign msg_out = order_msg_t'(s_axis_tdata[63 : 63 - $bits(order_msg_t) + 1]);
   assign msg_valid = s_axis_tvalid;
   assign s_axis_tready = msg_ready;

endmodule
