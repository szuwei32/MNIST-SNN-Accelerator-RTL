module TimeStep_FSM #(
    parameter int MAP_SIZE   = 26 * 26, // 676 valid pixels per channel
    parameter int MAX_FRAMES = 16       // T=16 time steps
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_lb_valid,    // Valid signal from LineBuffer
    output logic        o_clear_mem,   // Tells PE to clear Vmem (Frame 0)
    output logic [9:0]  o_vmem_addr,   // Address for Vmem SRAM (0 to 675)
    output logic        o_frame_done   // High when 1 image (16 frames) is totally done
);

    logic [9:0] pixel_cnt;
    logic [4:0] frame_cnt;

    // Address directly corresponds to the spatial pixel location
    assign o_vmem_addr = pixel_cnt;
    
    // Clear memory ONLY during the first frame iteration
    assign o_clear_mem = (frame_cnt == 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_cnt    <= '0;
            frame_cnt    <= '0;
            o_frame_done <= 1'b0;
        end else begin
            o_frame_done <= 1'b0; // Default low

            if (i_lb_valid) begin
                if (pixel_cnt == MAP_SIZE - 1) begin
                    pixel_cnt <= '0;
                    
                    // Frame tracking
                    if (frame_cnt == MAX_FRAMES - 1) begin
                        frame_cnt    <= '0;
                        o_frame_done <= 1'b1; // Trigger done signal for downstream
                    end else begin
                        frame_cnt <= frame_cnt + 1;
                    end
                end else begin
                    pixel_cnt <= pixel_cnt + 1;
                end
            end
        end
    end

`ifdef FORMAL
    // Formal safety properties — immediate assertions clocked on clk,
    // proven unbounded via SymbiYosys mode prove (k-induction).
    logic f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // start verification from a clean reset
    initial assume (!rst_n);

    // Vmem address always within the valid spatial map range
    always @(posedge clk)
        if (rst_n) AST_addr_in_range: assert (o_vmem_addr < MAP_SIZE);

    // frame counter never wraps past T-1
    always @(posedge clk)
        if (rst_n) AST_frame_in_range: assert (frame_cnt < MAX_FRAMES);

    // frame_done is a single-cycle pulse — never high two cycles running
    always @(posedge clk)
        if (f_past_valid && $past(rst_n) && rst_n && $past(o_frame_done))
            AST_frame_done_pulse: assert (!o_frame_done);
`endif

endmodule