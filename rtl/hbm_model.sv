// hbm_model.sv — behavioral HBM model with three independent port sets
// Port A: burst read/write for L1 replenishment and eviction
// Port B: regular read + byte-enable write for out-of-window message handling
// Port C: regular read + byte-enable write for pool update handling
// Known limitation: one outstanding read at a time per port
// Known limitation: write-during-read to same address returns pre-write value (no forwarding)
// Known limitation: Port A > Port B > Port C write priority on address collision

module hbm_model #(
    parameter type T               = logic [7:0],
    parameter int  DEPTH           = 256,
    parameter int  READ_LATENCY    = 10,
    parameter int  MAX_BURST       = 64,
    localparam int ADDR_WIDTH      = $clog2(DEPTH),
    localparam int NUM_BYTES       = $bits(T) / 8,
    localparam int BURST_LEN_WIDTH = $clog2(MAX_BURST) + 1
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Port A — burst read/write
    input  logic                        a_wr_valid,
    input  logic [ADDR_WIDTH-1:0]       a_wr_addr,
    input  T                            a_wr_data,
    input  logic [BURST_LEN_WIDTH-1:0]  a_wr_len,
    output logic                        a_wr_ready,
    input  logic                        a_rd_valid,
    input  logic [ADDR_WIDTH-1:0]       a_rd_addr,
    input  logic [BURST_LEN_WIDTH-1:0]  a_rd_len,
    output T                            a_rd_data,
    output logic                        a_rd_data_valid,
    output logic                        a_busy,

    // Port B — regular read + byte-enable write
    input  logic                        b_wr_valid,
    input  logic [ADDR_WIDTH-1:0]       b_wr_addr,
    input  logic [NUM_BYTES-1:0]        b_wr_byte_en,
    input  T                            b_wr_data,
    input  logic                        b_rd_valid,
    input  logic [ADDR_WIDTH-1:0]       b_rd_addr,
    output T                            b_rd_data,
    output logic                        b_rd_data_valid,
    output logic                        b_busy,

    // Port C — regular read + byte-enable write
    input  logic                        c_wr_valid,
    input  logic [ADDR_WIDTH-1:0]       c_wr_addr,
    input  logic [NUM_BYTES-1:0]        c_wr_byte_en,
    input  T                            c_wr_data,
    input  logic                        c_rd_valid,
    input  logic [ADDR_WIDTH-1:0]       c_rd_addr,
    output T                            c_rd_data,
    output logic                        c_rd_data_valid,
    output logic                        c_busy
);

    // Assertions
    initial begin
        assert (DEPTH > 0 && $onehot(DEPTH))
            else $fatal(1, "hbm_model: DEPTH must be a power of 2");
        assert (READ_LATENCY > 0)
            else $fatal(1, "hbm_model: READ_LATENCY must be at least 1");
        assert (MAX_BURST >= 1 && MAX_BURST <= DEPTH)
            else $fatal(1, "hbm_model: MAX_BURST must be in range [1, DEPTH]");
    end
    always_ff @(posedge clk) begin
        if (a_wr_valid)
            assert (a_wr_len >= 1 && a_wr_len <= MAX_BURST)
                else $fatal(1, "hbm_model: a_wr_len out of range");
        if (a_rd_valid)
            assert (a_rd_len >= 1 && a_rd_len <= MAX_BURST)
                else $fatal(1, "hbm_model: a_rd_len out of range");
    end

    // Internal state
    T mem [0:DEPTH-1];

    // Port A burst state
    logic                        a_wr_active;
    logic [ADDR_WIDTH-1:0]       a_wr_addr_ptr;
    logic [BURST_LEN_WIDTH-1:0]  a_wr_remaining;
    logic [ADDR_WIDTH-1:0]       a_wr_addr_eff; // effective write address for arbitration (a_wr_addr during setup, a_wr_addr_ptr during active burst)

    logic                        a_rd_active;
    logic [ADDR_WIDTH-1:0]       a_rd_addr_ptr;
    logic [BURST_LEN_WIDTH-1:0]  a_rd_remaining;

    // Port A read pipeline
    logic [0:READ_LATENCY-1]     a_pipeline_valid;
    T                            a_pipeline_data  [0:READ_LATENCY-1];

    // Port B read pipeline
    logic [0:READ_LATENCY-1]     b_pipeline_valid;
    T                            b_pipeline_data  [0:READ_LATENCY-1];

    // Port C read pipeline
    logic [0:READ_LATENCY-1]     c_pipeline_valid;
    T                            c_pipeline_data  [0:READ_LATENCY-1];

    // Output assignments
    assign a_wr_active = (a_wr_remaining > 0);
    assign a_rd_active = (a_rd_remaining > 0);
    assign a_wr_addr_eff = a_wr_active ? a_wr_addr_ptr : a_wr_addr;
    assign a_wr_ready = !a_wr_active;
    assign a_rd_data = a_pipeline_data[READ_LATENCY-1];
    assign a_rd_data_valid = a_pipeline_valid[READ_LATENCY-1];
    assign a_busy = a_rd_active || (|a_pipeline_valid[0:READ_LATENCY-2]);

    assign b_rd_data = b_pipeline_data[READ_LATENCY-1];
    assign b_rd_data_valid = b_pipeline_valid[READ_LATENCY-1];
    assign b_busy = (|b_pipeline_valid[0:READ_LATENCY-2]);

    assign c_rd_data = c_pipeline_data[READ_LATENCY-1];
    assign c_rd_data_valid = c_pipeline_valid[READ_LATENCY-1];
    assign c_busy = (|c_pipeline_valid[0:READ_LATENCY-2]);

    // Port A sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < READ_LATENCY; i++) begin
                a_pipeline_valid[i] <= 1'b0;
            end
            a_wr_remaining <= '0;
            a_rd_remaining <= '0;
        end else begin
            for (int i = READ_LATENCY-1; i > 0; i--) begin
                a_pipeline_valid[i] <= a_pipeline_valid[i-1];
                a_pipeline_data[i] <= a_pipeline_data[i-1];
            end

            // Port A burst write state machine
            if (a_wr_valid) begin
                if (a_wr_active) begin
                    a_wr_addr_ptr <= a_wr_addr_ptr + 1;
                    a_wr_remaining <= a_wr_remaining - 1;
                end else begin
                    a_wr_addr_ptr <= a_wr_addr + 1;
                    a_wr_remaining <= a_wr_len - 1;
                end
            end

            // Port A burst read state machine
            if (a_rd_active) begin
                a_pipeline_valid[0] <= 1'b1;
                a_pipeline_data[0] <= mem[a_rd_addr_ptr];
                a_rd_addr_ptr <= a_rd_addr_ptr + 1;
                a_rd_remaining <= a_rd_remaining - 1;
            end else if (a_rd_valid && !a_busy) begin
                a_pipeline_valid[0] <= 1'b1;
                a_pipeline_data[0] <= mem[a_rd_addr];
                a_rd_addr_ptr <= a_rd_addr + 1;
                a_rd_remaining <= a_rd_len - 1;
            end else begin
                a_pipeline_valid[0] <= 1'b0;
            end
        end
    end

    // Port B sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < READ_LATENCY; i++) begin
                b_pipeline_valid[i] <= 1'b0;
            end
        end else begin
            for (int i = READ_LATENCY-1; i > 0; i--) begin
                b_pipeline_valid[i] <= b_pipeline_valid[i-1];
                b_pipeline_data[i] <= b_pipeline_data[i-1];
            end

            if (b_rd_valid && !b_busy) begin
                b_pipeline_valid[0] <= 1'b1;
                b_pipeline_data[0] <= mem[b_rd_addr];
            end else begin
                b_pipeline_valid[0] <= 1'b0;
            end
        end
    end

    // Port C sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < READ_LATENCY; i++) begin
                c_pipeline_valid[i] <= 1'b0;
            end
        end else begin
            for (int i = READ_LATENCY-1; i > 0; i--) begin
                c_pipeline_valid[i] <= c_pipeline_valid[i-1];
                c_pipeline_data[i] <= c_pipeline_data[i-1];
            end

            if (c_rd_valid && !c_busy) begin
                c_pipeline_valid[0] <= 1'b1;
                c_pipeline_data[0] <= mem[c_rd_addr];
            end else begin
                c_pipeline_valid[0] <= 1'b0;
            end
        end
    end

    // Write arbitration logic
    always_ff @(posedge clk) begin
        // Port A write (highest priority)
        if (a_wr_valid) begin
            mem[a_wr_addr_eff] <= a_wr_data;
        end

        // Port B write (if not conflicting with A)
        if (b_wr_valid && !(a_wr_valid && a_wr_addr_eff == b_wr_addr)) begin
            for (int i = 0; i < NUM_BYTES; i++) begin
                if (b_wr_byte_en[i]) begin
                    mem[b_wr_addr][i*8 +: 8] <= b_wr_data[i*8 +: 8];
                end
            end
        end

        // Port C write (if not conflicting with A or B)
        if (c_wr_valid && !(a_wr_valid && a_wr_addr_eff == c_wr_addr) && !(b_wr_valid && b_wr_addr == c_wr_addr)) begin
            for (int i = 0; i < NUM_BYTES; i++) begin
                if (c_wr_byte_en[i]) begin
                    mem[c_wr_addr][i*8 +: 8] <= c_wr_data[i*8 +: 8];
                end
            end
        end
    end

endmodule
