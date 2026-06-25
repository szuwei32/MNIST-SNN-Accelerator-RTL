// =============================================================================
// FC_Serial.sv  —  SRAM-friendly serialized fully-connected layer
//
// Memory organisation: 10 FCWeightSRAM banks, one per output class.
//   Bank k depth = INPUT_LEN × NUM_CHANNELS = 169 × 8 = 1352 entries × 8-bit.
//   Bank k, address a  ≡  weight for class k, spatial pos a/8, channel a%8.
//   Flat file mapping: bank k[a] = weights_fc.hex[k × 1352 + a].
//
// SRAM timing model (macro-accurate, 1-cycle read latency):
//   Cycle T  : drive sram_addr, assert csb=0  →  SRAM clocks address.
//   Cycle T+1: sram_rdata[k] = registered output from FCWeightSRAM.
//
// Serialisation schedule (8 sub-cycles per pooled input position):
//   sub_cnt = 0  IDLE  — accept pool data; pre-issue addr for ch 0.
//   sub_cnt = 1  consume ch 0 (registered); issue addr for ch 1.
//   sub_cnt = 2  consume ch 1; issue addr for ch 2.
//   ...
//   sub_cnt = 7  consume ch 6; issue addr for ch 7.
//   sub_cnt = 8  consume ch 7; perform LIF update; return to IDLE.
//
// sram_addr at sub_cnt n  = pos_cnt × NUM_CHANNELS + n   (for n = 0 .. 7)
// csb                     = 0 when sub_cnt < NUM_CHANNELS and
//                               (sub_cnt > 0 or s_axis_valid)
//
// LIF logic is bit-exact with FullyConnected.sv:
//   • v_mem leaks by arithmetic right-shift-1 each frame-step.
//   • Fires when (v_mem_leaked + frame_dot_product) >= FC_V_THRESH.
//   • v_mem resets to 0 at last frame regardless of firing (matching original).
//
// Backpressure: s_axis_ready = 1 only when idle (sub_cnt == 0).
// Upstream Top_System_SRAM holds a depth-4 skid FIFO between AvgPooling and
// this module; the FIFO absorbs in-flight pool_valid pulses during processing.
// =============================================================================
module FC_Serial #(
    parameter int INPUT_LEN    = 169,
    parameter int NUM_CLASSES  = 10,
    parameter int NUM_CHANNELS = 8,
    parameter int DATA_WIDTH   = 8,
    parameter int ACC_WIDTH    = 32,
    parameter int MAX_FRAMES   = 16,
    parameter int FC_V_THRESH  = 643
) (
    input  logic                             clk,
    input  logic                             rst_n,

    // Pool input — with backpressure
    input  logic                             s_axis_valid,
    input  logic [NUM_CHANNELS-1:0][2:0]     s_axis_pool,
    output logic                             s_axis_ready,

    output logic                             done,
    output logic [NUM_CLASSES*32-1:0]        flat_spike_counts
);

    localparam int BANK_DEPTH = INPUT_LEN * NUM_CHANNELS; // 1352

    // =========================================================================
    // 10 FCWeightSRAM banks — one per output class
    // All banks share the same address and csb; rdata differs per bank.
    // =========================================================================
    logic [10:0]                   sram_addr;  // word address driven combinationally
    logic                          csb;        // chip-select bar (active low)
    logic signed [DATA_WIDTH-1:0]  sram_rdata [0:NUM_CLASSES-1]; // registered outputs

    genvar gk;
    generate
        for (gk = 0; gk < NUM_CLASSES; gk++) begin : gen_bank
            FCWeightSRAM #(
                .DEPTH     (BANK_DEPTH),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(11),
                .BANK_ID   (gk),
                .NUM_BANKS (NUM_CLASSES)
            ) u_bank (
                .clk  (clk),
                .csb  (csb),
                .addr (sram_addr),
                .rdata(sram_rdata[gk])
            );
        end
    endgenerate

    // =========================================================================
    // State
    // =========================================================================
    // sub_cnt = 0  : IDLE  (s_axis_ready = 1)
    // sub_cnt = 1..NUM_CHANNELS : processing channels 0..(NUM_CHANNELS-1)
    logic [3:0] sub_cnt;
    logic [7:0] pos_cnt;    // 0 .. INPUT_LEN-1
    logic [3:0] frame_cnt;  // 0 .. MAX_FRAMES-1

    // Pool data latched on accept (valid for the full 8 sub-cycles)
    logic [2:0] pool_buf [0:NUM_CHANNELS-1];

    logic signed [ACC_WIDTH-1:0] partial_sum [0:NUM_CLASSES-1]; // frame accumulator
    logic signed [ACC_WIDTH-1:0] v_mem       [0:NUM_CLASSES-1]; // LIF membrane
    logic        [31:0]          spike_count [0:NUM_CLASSES-1]; // per-image counts

    // =========================================================================
    // Combinational: SRAM address + chip-select + MAC + LIF intermediates
    //
    // sram_addr at sub_cnt n = pos_cnt × NUM_CHANNELS + n
    //   → n = 0 (accept cycle): pre-issue addr for ch 0
    //   → n = 1..7            : issue addr for ch n while consuming ch n-1 data
    //   → n = 8               : csb = 1, no new read; consume ch 7 data
    //
    // sram_rdata[k] is the REGISTERED output of FCWeightSRAM (1-cycle latency).
    // At sub_cnt = n (n ≥ 1), sram_rdata holds the weight for channel n-1.
    // =========================================================================
    logic signed [ACC_WIDTH-1:0] cur_mac     [0:NUM_CLASSES-1];
    logic signed [ACC_WIDTH-1:0] lif_v_total [0:NUM_CLASSES-1];
    logic signed [ACC_WIDTH-1:0] lif_v_leaked[0:NUM_CLASSES-1];
    logic signed [ACC_WIDTH-1:0] lif_v_next  [0:NUM_CLASSES-1];
    logic                        lif_fired   [0:NUM_CLASSES-1];

    always_comb begin
        // Address issued this cycle; SRAM delivers on the next posedge.
        sram_addr = 11'(pos_cnt) * NUM_CHANNELS + 11'(sub_cnt);

        // Active when: (a) accepting new input (sub_cnt=0, s_axis_valid=1), or
        //              (b) mid-computation issuing the next channel (sub_cnt=1..7).
        // Deasserted when: sub_cnt=0 and idle, or sub_cnt=8 (all channels done).
        csb = (sub_cnt == 4'(NUM_CHANNELS)) ||
              (sub_cnt == '0 && !s_axis_valid);

        for (int k = 0; k < NUM_CLASSES; k++) begin
            // sram_rdata[k] is the registered weight for channel (sub_cnt-1).
            // At sub_cnt=0 the value is stale; cur_mac is not consumed then.
            cur_mac[k] = $signed({1'b0,
                                   pool_buf[sub_cnt == '0 ? 0 : sub_cnt - 1]}) *
                         $signed(sram_rdata[k]);

            // LIF intermediates — valid at sub_cnt = NUM_CHANNELS (ch 7 data).
            // partial_sum[k] holds ch 0..6 contributions (accumulated sub_cnt 1..7).
            // cur_mac[k] adds ch 7 to complete the full-frame dot-product.
            lif_v_total[k]  = partial_sum[k] + cur_mac[k];
            lif_v_leaked[k] = $signed(v_mem[k]) >>> 1;
            lif_v_next[k]   = lif_v_leaked[k] + lif_v_total[k];
            lif_fired[k]    = ($signed(lif_v_next[k]) >= $signed(FC_V_THRESH));
        end
    end

    assign s_axis_ready = (sub_cnt == '0);

    // =========================================================================
    // Main sequential FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sub_cnt   <= '0;
            pos_cnt   <= '0;
            frame_cnt <= '0;
            done      <= 1'b0;
            for (int c = 0; c < NUM_CHANNELS; c++) pool_buf[c]   <= '0;
            for (int k = 0; k < NUM_CLASSES;  k++) begin
                partial_sum[k]              <= '0;
                v_mem[k]                    <= '0;
                spike_count[k]              <= '0;
                flat_spike_counts[k*32+:32] <= '0;
            end
        end else begin
            done <= 1'b0;

            // -----------------------------------------------------------------
            // IDLE: wait for the next pool output from the skid FIFO.
            // When accepted, latch pool data and move to sub_cnt = 1.
            // The SRAM address for ch 0 is already being driven combinationally;
            // FCWeightSRAM will clock it on this posedge (csb = 0 when valid).
            // -----------------------------------------------------------------
            if (sub_cnt == '0) begin
                if (s_axis_valid) begin
                    for (int c = 0; c < NUM_CHANNELS; c++)
                        pool_buf[c] <= s_axis_pool[c];
                    sub_cnt <= 4'd1;
                end

            // -----------------------------------------------------------------
            // CHANNELS 0..NUM_CHANNELS-2 (sub_cnt = 1..7):
            // Consume registered sram_rdata for channel (sub_cnt-1).
            // Accumulate MAC into partial_sum.
            // Address for channel sub_cnt is driven combinationally this cycle
            // and will be clocked by FCWeightSRAM on posedge (csb = 0).
            // -----------------------------------------------------------------
            end else if (sub_cnt < 4'(NUM_CHANNELS)) begin
                for (int k = 0; k < NUM_CLASSES; k++)
                    partial_sum[k] <= partial_sum[k] + cur_mac[k];
                sub_cnt <= sub_cnt + 1;

            // -----------------------------------------------------------------
            // LAST CHANNEL (sub_cnt = NUM_CHANNELS = 8, channel 7):
            // sram_rdata holds weight for ch 7 (registered from sub_cnt = 7).
            // cur_mac[k]    = ch 7 contribution.
            // lif_v_next[k] = complete frame LIF result.
            // -----------------------------------------------------------------
            end else begin
                sub_cnt <= '0;

                if (pos_cnt == 8'(INPUT_LEN - 1)) begin
                    // ---- End of frame: LIF update + spike accounting ----
                    for (int k = 0; k < NUM_CLASSES; k++) begin
                        if (lif_fired[k]) begin
                            v_mem[k] <= '0;
                            if (frame_cnt == 4'(MAX_FRAMES - 1)) begin
                                flat_spike_counts[k*32+:32] <= spike_count[k] + 1;
                                spike_count[k]              <= '0;
                            end else
                                spike_count[k] <= spike_count[k] + 1;
                        end else begin
                            // Reset v_mem at last frame even without firing,
                            // matching FullyConnected's end-of-image clear.
                            v_mem[k] <= (frame_cnt == 4'(MAX_FRAMES - 1))
                                        ? '0 : lif_v_next[k];
                            if (frame_cnt == 4'(MAX_FRAMES - 1)) begin
                                flat_spike_counts[k*32+:32] <= spike_count[k];
                                spike_count[k]              <= '0;
                            end
                        end
                        partial_sum[k] <= '0;
                    end

                    pos_cnt <= '0;
                    if (frame_cnt == 4'(MAX_FRAMES - 1)) begin
                        done      <= 1'b1;
                        frame_cnt <= '0;
                    end else
                        frame_cnt <= frame_cnt + 1;

                end else begin
                    // ---- Mid-frame: accumulate ch 7 and advance position ----
                    for (int k = 0; k < NUM_CLASSES; k++)
                        partial_sum[k] <= partial_sum[k] + cur_mac[k];
                    pos_cnt <= pos_cnt + 1;
                end
            end
        end
    end

endmodule
