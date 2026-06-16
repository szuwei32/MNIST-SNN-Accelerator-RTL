`timescale 1ns/1ps

module tb_Batch_Test;
    localparam int IMG_SIZE   = 28 * 28;
    localparam int MAX_FRAMES = 16;
    
    logic clk, rst_n, frame_rst_n;
    logic s_axis_valid, s_axis_ready, s_axis_last, done;
    logic [7:0] s_axis_data;
    logic [319:0] final_scores;
    logic [7:0] image_mem [0:IMG_SIZE-1];

    // DFT ports tied off in functional simulation
    logic scan_en, scan_in, scan_out;
    assign scan_en = 1'b0;
    assign scan_in = 1'b0;

    Top_System dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;


    logic hw_done_flag;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hw_done_flag <= 1'b0;
        else if (done) hw_done_flag <= 1'b1;
    end

    integer f_out;
    string img_filename;
    int img_idx, i, f;
    int best_class;
    logic [31:0] max_score;

    // -------------------------------------------------------------------------
    // Optional L1 spike dump (enabled with `vvp snn_sim +DUMP_L1`).
    // Captures the registered layer-1 conv spike vector every valid output
    // cycle, in image/frame/spatial(raster) order — 676 outputs/frame,
    // 16 frames/image, 100 images. Compared bit-for-bit against the golden
    // references by scripts/diff_l1.py.
    // -------------------------------------------------------------------------
    integer f_l1;
    logic   dump_l1;
    always_ff @(posedge clk) begin
        if (dump_l1 && dut.u_l1_conv.m_axis_valid)
            $fdisplay(f_l1, "%02x", dut.u_l1_conv.m_axis_spike);
    end

    // Sparsity measurement — accumulated across the whole 100-image batch.
    // (per-image rst_n is pulsed in the loop below, so the counters must NOT
    //  reset on rst_n or they would only report the last image.)
    longint total_windows, skipped_windows;
    initial begin
        total_windows   = 0;
        skipped_windows = 0;
    end
    always_ff @(posedge clk) begin
        if (dut.u_l1_conv.lb_valid) begin
            total_windows <= total_windows + 1;
            if (dut.u_l1_conv.o_skip)
                skipped_windows <= skipped_windows + 1;
        end
    end

    initial begin
        f_out = $fopen("hw_predictions.txt", "w");
        dump_l1 = $test$plusargs("DUMP_L1");
        if (dump_l1) begin
            f_l1 = $fopen("hw_l1_spikes.txt", "w");
            $display("=== L1 spike dump enabled -> hw_l1_spikes.txt ===");
        end
        $display("=== SNN Batch Testing Started (100 Images) ===");
        
        for (img_idx = 0; img_idx < 100; img_idx = img_idx + 1) begin
            rst_n        = 0;
            frame_rst_n  = 0;
            s_axis_valid = 0;
            s_axis_last  = 0;
            repeat(5) @(posedge clk);
            rst_n        = 1;
            frame_rst_n  = 1;
            @(posedge clk);

            $sformat(img_filename, "data/test_data/input_image_%0d.hex", img_idx);
            $readmemh(img_filename, image_mem);

            
            for (f = 0; f < MAX_FRAMES; f = f + 1) begin
                if (f > 0) begin
                    frame_rst_n <= 0;
                    @(posedge clk);
                    frame_rst_n <= 1;
                    @(posedge clk);
                end

                for (i = 0; i < IMG_SIZE; i = i + 1) begin
                    s_axis_valid <= 1'b1;
                    s_axis_data  <= image_mem[i];
                    s_axis_last  <= (i == IMG_SIZE - 1);
                    do begin @(posedge clk); end while (s_axis_ready == 1'b0);
                end
                s_axis_valid <= 1'b0;
                
                repeat(20) @(posedge clk); 
            end

            fork
                begin : wait_for_done
                    wait(hw_done_flag == 1'b1); 
                end
                begin : timeout
                    repeat(50000) @(posedge clk);
                    $display("[ERROR] Image %0d Timeout! FSM might be stuck.", img_idx);
                    $finish;
                end
            join_any
            disable fork;
            @(posedge clk);

            max_score = 0; 
            best_class = 0;
            for (int c = 0; c < 10; c = c + 1) begin
                if (final_scores[c*32 +: 32] > max_score) begin
                    max_score = final_scores[c*32 +: 32];
                    best_class = c;
                end
            end

            $fdisplay(f_out, "%0d", best_class);
            $fflush(f_out); 
            if (img_idx % 10 == 0) $display("Progress: %0d/100 images finished...", img_idx);
        end
        $fclose(f_out);
        if (dump_l1) $fclose(f_l1);
        $display("=== SNN Batch Testing Completed! ===");
        $display("=== Sparsity Report ===");
        $display("Total windows  : %0d", total_windows);
        $display("Skipped windows: %0d", skipped_windows);
        $display("Skip rate      : %.1f%%", 100.0 * skipped_windows / total_windows);
        $finish;
    end
endmodule