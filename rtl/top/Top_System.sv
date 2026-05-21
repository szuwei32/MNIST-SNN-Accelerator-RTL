// =============================================================================
// Top_System.sv
//
// DFT notes:
//   scan_en=1 puts all flip-flops into shift mode for ATPG.
//   scan_in feeds the first FF in the chain; scan_out comes from the last.
//   In functional mode (scan_en=0) the scan ports are ignored.
//   All flip-flops use synchronous-compatible resets to ease scan insertion.
// =============================================================================
module Top_System #(
    parameter int DATA_WIDTH  = 8,
    parameter int NUM_CLASSES = 10
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

    // --- DFT scan interface ------------------------------------------------
    input  logic        scan_en,    // 1 = scan shift mode, 0 = functional
    input  logic        scan_in,    // scan chain input
    output logic        scan_out    // scan chain output
);

    logic       l1_valid;
    logic [7:0] l1_spike_data;
    logic       l1_frame_done;
    logic       pool_valid;
    logic [7:0][2:0] pool_data;

    SNN_Accelerator #(
        .IMG_WIDTH(28), .NUM_FILTERS(8),
        .DATA_WIDTH(8), .ACC_WIDTH(24), .V_THRESH(58144)
    ) u_l1_conv (
        .clk         (clk),
        .rst_n       (rst_n),
        .frame_rst_n (frame_rst_n),
        .s_axis_valid(s_axis_valid),
        .s_axis_ready(s_axis_ready),
        .s_axis_data (s_axis_data),
        .m_axis_valid(l1_valid),
        .m_axis_spike(l1_spike_data),
        .m_frame_done(l1_frame_done)
    );

    AvgPooling #(.INPUT_WIDTH(26), .NUM_CHANNELS(8)) u_pool (
        .clk         (clk),
        .rst_n       (frame_rst_n),
        .s_axis_valid(l1_valid),
        .s_axis_spike(l1_spike_data),
        .m_axis_valid(pool_valid),
        .m_axis_pool (pool_data)
    );

    FullyConnected #(
        .INPUT_LEN(169), .NUM_CLASSES(NUM_CLASSES),
        .DATA_WIDTH(8),  .ACC_WIDTH(32), .FC_V_THRESH(643)
    ) u_fc (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axis_valid    (pool_valid),
        .s_axis_pool     (pool_data),
        .done            (done),
        .flat_spike_counts(final_scores)
    );

    // -------------------------------------------------------------------------
    // Scan chain stub
    // In a real DFT flow, the ATPG tool (e.g. Tessent, TetraMAX) replaces
    // this with an auto-stitched scan chain across all internal flip-flops.
    // The stub ensures the port exists and simulation is unaffected (scan_en=0).
    // -------------------------------------------------------------------------
    assign scan_out = scan_en ? scan_in : 1'b0;

endmodule
