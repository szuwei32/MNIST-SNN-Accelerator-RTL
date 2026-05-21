module FullyConnected #(
    parameter int INPUT_LEN   = 169,
    parameter int NUM_CLASSES = 10,
    parameter int DATA_WIDTH  = 8,
    parameter int ACC_WIDTH   = 32,
    parameter int FC_V_THRESH = 1024
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    s_axis_valid,
    input  logic [7:0][2:0]         s_axis_pool,

    output logic                    done,
    output logic [319:0]            flat_spike_counts
);

    localparam int NUM_CHANNELS  = 8;
    localparam int MAX_FRAMES    = 16;
    localparam int WEIGHT_STRIDE = INPUT_LEN * NUM_CHANNELS; // 1352

    // --- Weight memory ---
    logic signed [7:0] weights_mem [0 : NUM_CLASSES*WEIGHT_STRIDE-1];
`ifdef SIMULATION
    initial $readmemh("data/weights_fc.hex", weights_mem);
`endif

    // --- State registers ---
    logic [$clog2(INPUT_LEN)-1:0]  input_cnt;
    logic [$clog2(MAX_FRAMES)-1:0] frame_cnt;

    logic signed [ACC_WIDTH-1:0] partial_sum [0:NUM_CLASSES-1];
    logic signed [ACC_WIDTH-1:0] v_mem       [0:NUM_CLASSES-1];
    logic [31:0]                 spike_count [0:NUM_CLASSES-1];

    // ---------------------------------------------------------------
    // Stage 1 Comb: 10-class × 8-channel MAC
    // Breaks original 80-multiply critical path across a pipeline reg.
    // ---------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] cycle_dot_product [0:NUM_CLASSES-1];

    always_comb begin
        for (int k = 0; k < NUM_CLASSES; k++) begin
            cycle_dot_product[k] = '0;
            for (int c = 0; c < NUM_CHANNELS; c++)
                cycle_dot_product[k] = cycle_dot_product[k] +
                    ($signed({1'b0, s_axis_pool[c]}) *
                     weights_mem[k * WEIGHT_STRIDE + input_cnt * NUM_CHANNELS + c]);
        end
    end

    // ---------------------------------------------------------------
    // Stage 1 Register: pipeline MAC result + end-of-vector flags
    // ---------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] dp_reg       [0:NUM_CLASSES-1];
    logic                        dp_valid;
    logic [$clog2(INPUT_LEN)-1:0] input_cnt_d;
    logic                        frame_last_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dp_valid     <= 1'b0;
            input_cnt_d  <= '0;
            frame_last_d <= 1'b0;
            for (int k = 0; k < NUM_CLASSES; k++) dp_reg[k] <= '0;
        end else begin
            dp_valid     <= s_axis_valid && (frame_cnt < MAX_FRAMES);
            input_cnt_d  <= input_cnt;
            // Capture "last frame" flag so it travels with the pipeline data
            frame_last_d <= (frame_cnt == MAX_FRAMES - 1);
            for (int k = 0; k < NUM_CLASSES; k++) dp_reg[k] <= cycle_dot_product[k];
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: Counter + Accumulator + LIF (single always_ff, no
    //   multiple-driver issue — input_cnt/frame_cnt advance on
    //   s_axis_valid; accum/LIF fire one cycle later on dp_valid)
    // ---------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] v_leaked;
    logic signed [ACC_WIDTH-1:0] v_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_cnt <= '0;
            frame_cnt <= '0;
            done      <= 1'b0;
            for (int k = 0; k < NUM_CLASSES; k++) begin
                partial_sum[k]              <= '0;
                v_mem[k]                    <= '0;
                spike_count[k]              <= '0;
                flat_spike_counts[k*32+:32] <= '0;
            end
        end else begin
            done <= 1'b0;

            // --- Counter: advance one step ahead of the pipeline ---
            if (s_axis_valid && frame_cnt < MAX_FRAMES) begin
                if (input_cnt == INPUT_LEN - 1) begin
                    input_cnt <= '0;
                    frame_cnt <= (frame_cnt == MAX_FRAMES - 1) ? '0 : frame_cnt + 1;
                end else begin
                    input_cnt <= input_cnt + 1;
                end
            end

            // --- Accumulator + LIF: consume dp_reg from pipeline stage ---
            if (dp_valid) begin
                for (int k = 0; k < NUM_CLASSES; k++)
                    partial_sum[k] <= partial_sum[k] + dp_reg[k];

                if (input_cnt_d == INPUT_LEN - 1) begin
                    for (int k = 0; k < NUM_CLASSES; k++) begin
                        // v_leaked and v_next are shared temporaries — safe in
                        // sequential for-loop since each k is computed in order.
                        v_leaked = $signed(v_mem[k]) >>> 1;
                        v_next   = v_leaked + partial_sum[k] + dp_reg[k];

                        if ($signed(v_next) >= $signed(FC_V_THRESH)) begin
                            if (frame_last_d) begin
                                flat_spike_counts[k*32+:32] <= spike_count[k] + 1;
                                spike_count[k] <= '0;
                                v_mem[k]       <= '0;
                            end else begin
                                spike_count[k] <= spike_count[k] + 1;
                                v_mem[k]       <= '0;
                            end
                        end else begin
                            if (frame_last_d) begin
                                flat_spike_counts[k*32+:32] <= spike_count[k];
                                spike_count[k] <= '0;
                                v_mem[k]       <= '0;
                            end else begin
                                v_mem[k] <= v_next;
                            end
                        end
                        partial_sum[k] <= '0;
                    end
                    if (frame_last_d) done <= 1'b1;
                end
            end
        end
    end

endmodule
