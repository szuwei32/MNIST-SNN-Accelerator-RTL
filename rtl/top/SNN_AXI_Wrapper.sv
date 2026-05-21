// =============================================================================
// SNN_AXI_Wrapper.sv
//
// AXI4-Lite slave wrapper around Top_System, exposing a register-mapped
// control/status interface so the accelerator can be driven from a host CPU
// or integrated as an SoC IP block on an AXI interconnect.
//
// Register Map (byte-addressed, 32-bit registers):
//   0x00  CTRL     [0]=start  [1]=soft_rst  (write 1 to start inference)
//   0x04  STATUS   [0]=done   [1]=busy      (read-only)
//   0x08  RESULT   [3:0]=predicted_class    (argmax of spike counts, read after done)
//   0x0C  VERSION  [31:0]=0x0001_0000       (read-only, major.minor)
// =============================================================================
module SNN_AXI_Wrapper #(
    parameter int NUM_CLASSES   = 10,
    parameter int ADDR_WIDTH    = 4,   // covers 0x00–0x0C
    parameter int DATA_WIDTH    = 32
) (
    // AXI4-Lite Global
    input  logic                  aclk,
    input  logic                  aresetn,

    // AXI4-Lite Write Address Channel
    input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,

    // AXI4-Lite Write Data Channel
    input  logic [DATA_WIDTH-1:0] s_axil_wdata,
    input  logic [3:0]            s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,

    // AXI4-Lite Write Response Channel
    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,

    // AXI4-Lite Read Address Channel
    input  logic [ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,

    // AXI4-Lite Read Data Channel
    output logic [DATA_WIDTH-1:0] s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready,

    // AXI4-Stream pixel input (pass-through to Top_System)
    input  logic                  s_axis_valid,
    output logic                  s_axis_ready,
    input  logic [7:0]            s_axis_data,
    input  logic                  s_axis_last
);

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    localparam logic [31:0] REG_VERSION = 32'h0001_0000;

    logic        reg_start;     // CTRL[0]: self-clearing after 1 cycle
    logic        reg_soft_rst;  // CTRL[1]: drives frame_rst_n
    logic        reg_done;      // STATUS[0]: mirrors Top_System.done (latched)
    logic        reg_busy;      // STATUS[1]: high while inference is running
    logic [3:0]  reg_result;    // RESULT[3:0]: predicted class

    // Internal resets derived from register control
    logic rst_n_int;
    logic frame_rst_n_int;
    assign rst_n_int      = aresetn & ~reg_soft_rst;
    assign frame_rst_n_int = aresetn & ~reg_soft_rst;

    // -------------------------------------------------------------------------
    // Top_System outputs
    // -------------------------------------------------------------------------
    logic        sys_done;
    logic [319:0] sys_scores;

    Top_System #(.NUM_CLASSES(NUM_CLASSES)) u_top (
        .clk         (aclk),
        .rst_n       (rst_n_int),
        .frame_rst_n (frame_rst_n_int),
        .s_axis_valid(s_axis_valid & reg_busy), // gated: only accept data when running
        .s_axis_ready(s_axis_ready),
        .s_axis_data (s_axis_data),
        .s_axis_last (s_axis_last),
        .done        (sys_done),
        .final_scores(sys_scores)
    );

    // -------------------------------------------------------------------------
    // Argmax: find predicted class from spike counts
    // -------------------------------------------------------------------------
    logic [31:0] score_arr [0:NUM_CLASSES-1];
    always_comb begin
        for (int k = 0; k < NUM_CLASSES; k++)
            score_arr[k] = sys_scores[k*32 +: 32];
    end

    logic [3:0]  argmax_class;
    logic [31:0] argmax_val;
    always_comb begin
        argmax_class = '0;
        argmax_val   = '0;
        for (int k = 0; k < NUM_CLASSES; k++) begin
            if (score_arr[k] > argmax_val) begin
                argmax_val   = score_arr[k];
                argmax_class = k[3:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Busy / Done tracking
    // -------------------------------------------------------------------------
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_busy   <= 1'b0;
            reg_done   <= 1'b0;
            reg_result <= '0;
        end else begin
            if (reg_start)
                reg_busy <= 1'b1;
            if (sys_done) begin
                reg_busy   <= 1'b0;
                reg_done   <= 1'b1;
                reg_result <= argmax_class;
            end
            // Clear done flag when host writes CTRL.start again
            if (reg_start)
                reg_done <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Write Logic
    // -------------------------------------------------------------------------
    logic aw_active;  // write address received, waiting for wdata
    logic [ADDR_WIDTH-1:0] aw_addr_hold;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            aw_active      <= 1'b0;
            aw_addr_hold   <= '0;
            reg_start      <= 1'b0;
            reg_soft_rst   <= 1'b0;
        end else begin
            reg_start    <= 1'b0; // self-clearing
            reg_soft_rst <= 1'b0;

            // Accept write address
            if (s_axil_awvalid && !aw_active) begin
                s_axil_awready <= 1'b1;
                aw_addr_hold   <= s_axil_awaddr;
                aw_active      <= 1'b1;
            end else begin
                s_axil_awready <= 1'b0;
            end

            // Accept write data and perform register write
            if (s_axil_wvalid && aw_active) begin
                s_axil_wready <= 1'b1;
                aw_active     <= 1'b0;

                case (aw_addr_hold)
                    4'h0: begin // CTRL
                        if (s_axil_wdata[0]) reg_start    <= 1'b1;
                        if (s_axil_wdata[1]) reg_soft_rst <= 1'b1;
                    end
                    default: ; // writes to read-only registers are silently ignored
                endcase

                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00; // OKAY
            end else begin
                s_axil_wready <= 1'b0;
            end

            // Clear bvalid once handshake completes
            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Read Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rdata   <= '0;
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && !s_axil_rvalid) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;

                case (s_axil_araddr)
                    4'h0:    s_axil_rdata <= {30'b0, reg_soft_rst, reg_start}; // CTRL (reflect)
                    4'h4:    s_axil_rdata <= {30'b0, reg_busy, reg_done};      // STATUS
                    4'h8:    s_axil_rdata <= {28'b0, reg_result};               // RESULT
                    4'hC:    s_axil_rdata <= REG_VERSION;                       // VERSION
                    default: s_axil_rdata <= 32'hDEAD_BEEF;                    // unmapped
                endcase
            end else begin
                s_axil_arready <= 1'b0;
            end

            if (s_axil_rvalid && s_axil_rready)
                s_axil_rvalid <= 1'b0;
        end
    end

endmodule
