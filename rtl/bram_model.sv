// bram_model.sv — behavioral dual-port BRAM model with byte-enable write on Port B
//
// Known Limitations:
// - Port A read returns pre-write value if write to same address is in flight (no forwarding)
// - Port A and Port B simultaneous write to same address: Port A wins, Port B ignored
// - One outstanding Port A read at a time

module bram_model #(
    parameter type T            = logic [7:0],
    parameter int  DEPTH        = 256,
    parameter int  READ_LATENCY = 2,
    localparam int ADDR_WIDTH   = $clog2(DEPTH),
    localparam int NUM_BYTES    = $bits(T) / 8
)(
    input  logic                       clk,
    input  logic                       rst_n,
    
    // Port A
    input  logic                       a_valid,
    input  logic                       a_wr_en,      // 1=write, 0=read
    input  logic [ADDR_WIDTH-1:0]      a_addr,
    input  T                           a_wr_data,
    output T                           a_rd_data,
    output logic                       a_rd_data_valid,
    
    // Port B: Write with byte enables
    input  logic                       b_valid,
    input  logic [ADDR_WIDTH-1:0]      b_addr,
    input  logic [NUM_BYTES-1:0]       b_wr_byte_en,
    input  T                           b_wr_data
);

    // Parameter checks
    initial begin
        assert ($bits(T) % 8 == 0) else $fatal("T must be byte-aligned");
        assert (READ_LATENCY > 0) else $fatal("READ_LATENCY must be > 0");
    end

    // Byte-addressable memory array
    T mem [0:DEPTH-1];

    // Read pipeline shift registers
    logic                  pipeline_valid [0:READ_LATENCY-1];
    T                      pipeline_data [0:READ_LATENCY-1];

    // Port A: Read pipeline with configurable latency
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < READ_LATENCY; i++) begin
                pipeline_valid[i] <= 1'b0;
            end
        end else begin
            // Shift pipeline
            for (int i = READ_LATENCY-1; i > 0; i--) begin
                pipeline_valid[i] <= pipeline_valid[i-1];
                pipeline_data[i]  <= pipeline_data[i-1];
            end

            // Read from memory into pipeline stage 0
            if (a_valid && !a_wr_en) begin
                pipeline_valid[0] <= 1'b1;
                pipeline_data[0]  <= mem[a_addr];
            end else begin
                pipeline_valid[0] <= 1'b0;
            end
        end
    end

    // Output assignment from pipeline tail
    assign a_rd_data       = pipeline_data[READ_LATENCY-1];
    assign a_rd_data_valid = pipeline_valid[READ_LATENCY-1];

    // Port A: Write
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Memory does not need to be cleared
        end else begin
            if (a_valid && a_wr_en)
                mem[a_addr] <= a_wr_data;
        end
    end

    // Port B: Write with byte enables
    // Port A takes priority: if both ports write to same address, skip Port B
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Memory does not need to be cleared
        end else begin
            if (b_valid) begin
                // Only proceed if Port A is not writing to the same address
                if (!(a_valid && a_wr_en && (a_addr == b_addr))) begin
                    for (int i = 0; i < NUM_BYTES; i++) begin
                        if (b_wr_byte_en[i]) begin
                            mem[b_addr][i*8 +: 8] <= b_wr_data[i*8 +: 8];
                        end
                    end
                end
            end
        end
    end

endmodule
