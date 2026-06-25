// =============================================================================
// Top_System_SRAM.sv  —  Conv + Pool + skid FIFO + FC_Serial
//
// External port list is identical to Top_System.sv so the same testbench
// harness can drive either design (just swap the DUT module name).
//
// Backpressure chain
// ──────────────────
//   FC_Serial busy (sub_cnt≠0)
//     → fc_ready = 0
//     → skid FIFO absorbs pool_valid while FC is processing
//     → when fifo_count ≥ FIFO_DEPTH-2 (almost-full), gate pixel input:
//         gated_valid  = s_axis_valid && !fifo_almost_full
//         s_axis_ready = !fifo_almost_full   (testbench stalls via ready)
//
// In-flight analysis
// ──────────────────
//   When gated_valid drops on posedge T:
//     LineBuffer clears lb_valid at posedge T.
//     SNN_Acc propagates: m_axis_valid = 0 at posedge T+1.
//     AvgPooling may still fire pool_valid at posedge T+1 (from lb at T-1
//     via m_axis_valid at T).
//   → at most 1 stale pool_valid arrives after gating.
//   FIFO depth 4, stall threshold 2 → 2 free slots → safe.
// =============================================================================
module Top_System_SRAM #(
    parameter int DATA_WIDTH   = 8,
    parameter int NUM_CLASSES  = 10,
    parameter int NUM_CHANNELS = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        frame_rst_n,
    input  logic        s_axis_valid,
    output logic        s_axis_ready,
    input  logic [7:0]  s_axis_data,
    input  logic        s_axis_last,
    output logic        done,
    output logic [319:0] final_scores,

    // DFT scan stub (tied off, same as Top_System)
    input  logic        scan_en,
    input  logic        scan_in,
    output logic        scan_out
);

    // =========================================================================
    // 1. Skid FIFO parameters / signals (declared early; used in gate logic)
    // =========================================================================
    localparam int POOL_W     = NUM_CHANNELS * 3; // 8ch × 3bit = 24 bits
    localparam int FIFO_DEPTH = 4;

    logic [POOL_W-1:0] fifo_mem   [0:FIFO_DEPTH-1];
    logic [1:0]        fifo_wptr, fifo_rptr; // 2-bit circular (auto wraps mod 4)
    logic [2:0]        fifo_count;           // 0..FIFO_DEPTH
    logic              fifo_full, fifo_empty, fifo_almost_full;
    logic              fifo_wr, fifo_rd;
    logic [POOL_W-1:0] fifo_rdata;

    assign fifo_full        = (fifo_count == FIFO_DEPTH[2:0]);
    assign fifo_empty       = (fifo_count == '0);
    // Stall upstream when 2 or more entries queued; leaves 2 free for in-flight drain.
    assign fifo_almost_full = (fifo_count >= 3'(FIFO_DEPTH - 2));

    assign fifo_rdata = fifo_mem[fifo_rptr];

    // =========================================================================
    // 2. Pixel-input gate
    // =========================================================================
    logic gated_valid;
    assign gated_valid  = s_axis_valid && !fifo_almost_full;
    assign s_axis_ready = !fifo_almost_full;

    // =========================================================================
    // 3. Conv layer (SNN_Accelerator)
    // =========================================================================
    logic       l1_valid;
    logic [7:0] l1_spike;
    logic       l1_frame_done;
    logic       _unused_conv_ready; // SNN_Accelerator.s_axis_ready is always 1

    SNN_Accelerator #(
        .IMG_WIDTH(28), .NUM_FILTERS(8),
        .DATA_WIDTH(8), .ACC_WIDTH(24), .V_THRESH(58144)
    ) u_l1_conv (
        .clk         (clk),
        .rst_n       (rst_n),
        .frame_rst_n (frame_rst_n),
        .s_axis_valid(gated_valid),
        .s_axis_ready(_unused_conv_ready),
        .s_axis_data (s_axis_data),
        .m_axis_valid(l1_valid),
        .m_axis_spike(l1_spike),
        .m_frame_done(l1_frame_done)
    );

    // =========================================================================
    // 4. AvgPooling
    // =========================================================================
    logic                         pool_valid;
    logic [NUM_CHANNELS-1:0][2:0] pool_data;

    AvgPooling #(
        .INPUT_WIDTH (26),
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_pool (
        .clk         (clk),
        .rst_n       (frame_rst_n),
        .s_axis_valid(l1_valid),
        .s_axis_spike(l1_spike),
        .m_axis_valid(pool_valid),
        .m_axis_pool (pool_data)
    );

    // =========================================================================
    // 5. Skid FIFO (write side: pool → FIFO; read side: FIFO → FC_Serial)
    // =========================================================================
    logic fc_ready; // FC_Serial.s_axis_ready

    assign fifo_wr = pool_valid && !fifo_full;
    assign fifo_rd = fc_ready   && !fifo_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wptr  <= '0;
            fifo_rptr  <= '0;
            fifo_count <= '0;
        end else begin
            if (fifo_wr) begin
                fifo_mem[fifo_wptr] <= pool_data; // [7:0][2:0] packs to 24-bit flat
                fifo_wptr           <= fifo_wptr + 1; // wraps at 4 (2-bit ptr)
            end
            if (fifo_rd)
                fifo_rptr <= fifo_rptr + 1;

            unique case ({fifo_wr, fifo_rd})
                2'b10:   fifo_count <= fifo_count + 1;
                2'b01:   fifo_count <= fifo_count - 1;
                default: ; // 00 or 11: count unchanged
            endcase
        end
    end

`ifdef SIMULATION
    always @(posedge clk) begin
        if (pool_valid && fifo_full)
            $error("[Top_System_SRAM] Skid FIFO overflow at time %0t", $time);
    end
`endif

    // =========================================================================
    // 6. FC_Serial
    // =========================================================================
    logic [NUM_CHANNELS-1:0][2:0] fc_pool_in;
    assign fc_pool_in = fifo_rdata; // 24-bit flat → packed [7:0][2:0]

    FC_Serial #(
        .INPUT_LEN   (169),
        .NUM_CLASSES (NUM_CLASSES),
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH  (8),
        .ACC_WIDTH   (32),
        .MAX_FRAMES  (16),
        .FC_V_THRESH (643)
    ) u_fc (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axis_valid    (!fifo_empty),
        .s_axis_pool     (fc_pool_in),
        .s_axis_ready    (fc_ready),
        .done            (done),
        .flat_spike_counts(final_scores)
    );

    // DFT scan stub
    assign scan_out = scan_en ? scan_in : 1'b0;

endmodule
