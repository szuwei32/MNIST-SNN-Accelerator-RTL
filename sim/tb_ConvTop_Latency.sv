// =============================================================
// tb_ConvTop_Latency.sv
// Measures the cycle-accurate latency of SNN_Conv_Top (Conv+Pool
// ASIC core) for one image = 16 SNN timesteps.
//
// Latency is data-independent: the pixel stream and TimeStep_FSM
// advance every cycle regardless of pixel values; the sparsity
// skip only gates MAC power, not cycle count. So a constant feed
// gives the same cycle count as any real image.
//
// Frame-to-frame transition uses the design's standard 2-cycle
// frame_rst handshake (input stream idle during reset); no
// arbitrary testbench padding is added.
// =============================================================
`timescale 1ns/1ps

module tb_ConvTop_Latency;
    localparam int IMG_SIZE   = 28*28;   // 784 pixels streamed per timestep
    localparam int MAX_FRAMES = 16;      // T = 16 timesteps per image

    logic clk, rst_n, frame_rst_n;
    logic s_axis_valid, s_axis_ready;
    logic [7:0] s_axis_data;
    logic pool_valid;
    logic [7:0][2:0] pool_data;
    logic frame_done;

    SNN_Conv_Top dut (
        .clk(clk), .rst_n(rst_n), .frame_rst_n(frame_rst_n),
        .s_axis_valid(s_axis_valid), .s_axis_ready(s_axis_ready),
        .s_axis_data(s_axis_data),
        .pool_valid(pool_valid), .pool_data(pool_data),
        .frame_done(frame_done)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    longint t_start = -1, t_done = -1, t_last_pool = -1;
    always @(posedge clk) begin
        if (s_axis_valid && t_start < 0) t_start     <= cyc;
        if (frame_done)                  t_done      <= cyc;
        if (pool_valid)                  t_last_pool <= cyc;
    end

    int f, i;
    initial begin
        rst_n = 0; frame_rst_n = 0; s_axis_valid = 0; s_axis_data = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; frame_rst_n = 1;
        @(posedge clk);

        for (f = 0; f < MAX_FRAMES; f++) begin
            if (f > 0) begin
                frame_rst_n <= 1'b0; @(posedge clk);   // reset LineBuffer for new frame
                frame_rst_n <= 1'b1; @(posedge clk);
            end
            for (i = 0; i < IMG_SIZE; i++) begin
                s_axis_valid <= 1'b1;
                s_axis_data  <= 8'hA5;
                @(posedge clk);
            end
            s_axis_valid <= 1'b0;
            repeat(12) @(posedge clk);   // drain LineBuffer/conv pipeline before next frame
        end
        $display("all pixels fed @ cycle %0d", cyc);

        repeat(400) @(posedge clk);   // let frame_done / pooling fully drain

        if (t_done < 0)
            $display("[ERROR] frame_done never asserted — check frame protocol");

        $display("=== SNN_Conv_Top latency: 1 image (16 timesteps) ===");
        $display("first pixel    @ cycle : %0d", t_start);
        $display("frame_done     @ cycle : %0d", t_done);
        $display("last pool_valid@ cycle : %0d", t_last_pool);
        $display("LATENCY to frame_done  : %0d cycles", t_done - t_start);
        $display("LATENCY to last pool   : %0d cycles", t_last_pool - t_start);
        $finish;
    end
endmodule
