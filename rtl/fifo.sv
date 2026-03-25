// fifo.sv — generic synchronous circular FIFO for Exchangine

module fifo #(
    parameter type T     = logic,
    parameter int  DEPTH = 8
)(
    input  logic  clk,
    input  logic  rst_n,
    input  T      din,
    input  logic  push,
    output logic  full,
    output T      dout,
    input  logic  pop,
    output logic  empty
);

    localparam PTR_WIDTH = $clog2(DEPTH);

    // Internal state
    T                   buff [0:DEPTH-1];
    logic [PTR_WIDTH:0] wr_ptr;
    logic [PTR_WIDTH:0] rd_ptr;

    // Generate-time assertion for DEPTH being power of 2
    initial assert ($onehot(DEPTH)) else $fatal(1, "fifo: DEPTH must be a power of 2");

    // Pointer updates
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (push && !full) begin
                buff[wr_ptr[PTR_WIDTH-1:0]] <= din;
                wr_ptr <= wr_ptr + 1;
            end
            if (pop && !empty) begin
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

    // Empty and full flags
    assign empty = (wr_ptr == rd_ptr);
    assign full = (wr_ptr[PTR_WIDTH-1:0] == rd_ptr[PTR_WIDTH-1:0]) && (wr_ptr[PTR_WIDTH] != rd_ptr[PTR_WIDTH]);

    // Data output
    assign dout = buff[rd_ptr[PTR_WIDTH-1:0]];

endmodule
