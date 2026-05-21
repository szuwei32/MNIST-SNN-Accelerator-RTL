module SNN_Accelerator #(
    parameter int IMG_WIDTH   = 28,
    parameter int NUM_FILTERS = 8,
    parameter int DATA_WIDTH  = 8,
    parameter int ACC_WIDTH   = 18,
    parameter int V_THRESH    = 59723
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_rst_n, 
    input  logic       s_axis_valid,
    output logic       s_axis_ready, 
    input  logic [7:0] s_axis_data,
    output logic       m_axis_valid,
    output logic [NUM_FILTERS-1:0] m_axis_spike, 
    output logic       m_frame_done              
);

    logic                  lb_valid;
    logic [8:0][7:0]       lb_window;
    logic                  o_skip;
    logic                  o_fire_enable;
    logic                  fsm_clear_mem;
    logic [9:0]            vmem_addr;
    logic [9:0]            waddr_q; 
    
    logic signed [ACC_WIDTH-1:0] vmem_read_data  [0:NUM_FILTERS-1];
    logic signed [ACC_WIDTH-1:0] vmem_write_data [0:NUM_FILTERS-1];
    logic                        pe_vmem_valid   [0:NUM_FILTERS-1];
    logic [7:0] weights_mem_flat [0:NUM_FILTERS*9-1];
    logic signed [8:0][7:0] weights_mem [0:NUM_FILTERS-1];
    assign s_axis_ready = 1'b1;

    LineBuffer #(.IMG_WIDTH(IMG_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_linebuffer (
        .clk(clk), .rst_n(frame_rst_n), .i_valid(s_axis_valid & s_axis_ready), 
        .i_data(s_axis_data), .o_valid(lb_valid), .o_window(lb_window)
    );

    SparsityController u_sparsity (
        .i_window(lb_window), .i_valid(lb_valid),
        .o_skip(o_skip), .o_fire_enable(o_fire_enable) 
    );

    TimeStep_FSM u_fsm (
        .clk(clk), .rst_n(rst_n), .i_lb_valid(lb_valid),
        .o_clear_mem(fsm_clear_mem), .o_vmem_addr(vmem_addr), .o_frame_done(m_frame_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) waddr_q <= '0;
        else if (lb_valid) waddr_q <= vmem_addr;
    end

`ifdef SIMULATION
    initial begin
        $readmemh("data/weights_conv.hex", weights_mem_flat);
        for (int f = 0; f < NUM_FILTERS; f++) begin
            for (int k = 0; k < 9; k++) weights_mem[f][k] = weights_mem_flat[f*9 + k];
        end
    end
`endif

    genvar gi;
    generate
        for (gi = 0; gi < NUM_FILTERS; gi = gi + 1) begin : GEN_PE_CHANNEL
            Vmem_Array #(.ACC_WIDTH(ACC_WIDTH)) u_vmem (
                .clk(clk), .i_we(pe_vmem_valid[gi]), .i_raddr(vmem_addr),
                .i_waddr(waddr_q), .i_wdata(vmem_write_data[gi]), .o_rdata(vmem_read_data[gi])
            );

            ConvPE #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .V_THRESH(V_THRESH)) u_pe (
                .clk(clk), .rst_n(rst_n), .i_valid(lb_valid),
                .i_clear_mem(fsm_clear_mem), .i_vmem_read(vmem_read_data[gi]),
                .i_window(lb_window), .i_weights(weights_mem[gi]),
                .i_skip(o_skip),
                .o_spike(m_axis_spike[gi]), .o_vmem_valid(pe_vmem_valid[gi]),
                .o_vmem_write(vmem_write_data[gi])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m_axis_valid <= 1'b0;
        else m_axis_valid <= lb_valid;
    end
endmodule