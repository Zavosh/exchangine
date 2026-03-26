// hbm_model.sv — behavioral HBM model with parameterized read latency
// Known limitation: write-during-read to same address returns pre-write value (no forwarding)
// Known limitation: one outstanding read at a time — rd_valid ignored when busy

module hbm_model #(
    parameter type T            = logic [7:0],
    parameter int  DEPTH        = 64,
    parameter int  READ_LATENCY = 10,
    localparam ADDR_WIDTH = $clog2(DEPTH)
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      wr_valid,
    input  logic [ADDR_WIDTH-1:0]     wr_addr,
    input  T                          wr_data,
    input  logic                      rd_valid,
    input  logic [ADDR_WIDTH-1:0]     rd_addr,
    output T                          rd_data,
    output logic                      rd_data_valid,
    output logic                      busy
);

    // Assertions for parameter validation
    initial assert (DEPTH > 0 && $onehot(DEPTH)) else $fatal(1, "hbm_model: DEPTH must be a power of 2");
    initial assert (READ_LATENCY > 0) else $fatal(1, "hbm_model: READ_LATENCY must be at least 1");

    // Internal state
    T mem [0:DEPTH-1];
    logic pipeline_valid [0:READ_LATENCY-1];
    T pipeline_data [0:READ_LATENCY-1];

    // Compute busy signal (high if any pipeline stage has valid data)
    logic busy_internal;
    always_comb begin
        busy_internal = 1'b0;
        for (int i = 0; i < READ_LATENCY-1; i++) begin
            busy_internal = busy_internal | pipeline_valid[i];
        end
    end

    // Output assignments
    assign busy = busy_internal;
    assign rd_data_valid = pipeline_valid[READ_LATENCY-1];
    assign rd_data = pipeline_data[READ_LATENCY-1];

    // Sequential logic for writes and pipeline shifts
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear all pipeline_valid bits on reset
            for (int i = 0; i < READ_LATENCY; i++) begin
                pipeline_valid[i] <= 1'b0;
            end
        end else begin
            // Shift pipeline forward: pipeline_valid[i] <= pipeline_valid[i-1]
            for (int i = READ_LATENCY-1; i > 0; i--) begin
                pipeline_valid[i] <= pipeline_valid[i-1];
                pipeline_data[i] <= pipeline_data[i-1];
            end

            // Handle new read at pipeline input (stage 0)
            if (rd_valid && !busy_internal) begin
                pipeline_valid[0] <= 1'b1;
                pipeline_data[0] <= mem[rd_addr];
            end else begin
                pipeline_valid[0] <= 1'b0;
            end

            // Handle write (posted write)
            if (wr_valid) begin
                mem[wr_addr] <= wr_data;
            end
        end
    end

endmodule
