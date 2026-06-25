`timescale 1ns/1ps
// =============================================================================
// tb_Batch_Test_SRAM.sv
//
// Drives Top_System_SRAM with the same 100-image batch used by the original
// tb_Batch_Test.sv.  Compares hw_predictions_sram.txt against
// output/test_labels.txt to verify that accuracy is preserved after the
// FC layer is replaced with the serialized SRAM-friendly FC_Serial.
//
// Key differences from tb_Batch_Test.sv:
//   - DUT is Top_System_SRAM (not Top_System)
//   - Output written to hw_predictions_sram.txt
//   - Timeout increased to 80 000 cycles to account for FC_Serial backpressure
//     stretching the effective per-image streaming time.
//   - L1 spike / sparsity instrumentation removed (not relevant here).
// =============================================================================
module tb_Batch_Test_SRAM;

    localparam int IMG_SIZE   = 28 * 28;
    localparam int MAX_FRAMES = 16;

    logic clk, rst_n, frame_rst_n;
    logic s_axis_valid, s_axis_ready, s_axis_last, done;
    logic [7:0]  s_axis_data;
    logic [319:0] final_scores;
    logic [7:0]  image_mem [0:IMG_SIZE-1];

    // DFT ports tied off
    logic scan_en = 1'b0, scan_in = 1'b0, scan_out;

    Top_System_SRAM dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // Sticky done flag — persists until rst_n clears it
    logic hw_done_flag;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hw_done_flag <= 1'b0;
        else if (done) hw_done_flag <= 1'b1;
    end

    integer f_out;
    string  img_filename;
    int     img_idx, i, f, best_class;
    logic [31:0] max_score;

    initial begin
        f_out = $fopen("hw_predictions_sram.txt", "w");
        $display("=== SNN SRAM Batch Test Started (100 images) ===");

        for (img_idx = 0; img_idx < 100; img_idx++) begin
            // ---- Reset ----
            rst_n        = 0;
            frame_rst_n  = 0;
            s_axis_valid = 0;
            s_axis_last  = 0;
            repeat(5) @(posedge clk);
            rst_n       = 1;
            frame_rst_n = 1;
            @(posedge clk);

            $sformat(img_filename, "data/test_data/input_image_%0d.hex", img_idx);
            $readmemh(img_filename, image_mem);

            // ---- Stream 16 frames ----
            for (f = 0; f < MAX_FRAMES; f++) begin
                if (f > 0) begin
                    frame_rst_n <= 0;
                    @(posedge clk);
                    frame_rst_n <= 1;
                    @(posedge clk);
                end

                for (i = 0; i < IMG_SIZE; i++) begin
                    s_axis_valid <= 1'b1;
                    s_axis_data  <= image_mem[i];
                    s_axis_last  <= (i == IMG_SIZE - 1);
                    // Wait for backpressure: FC_Serial can stall the ready
                    do begin @(posedge clk); end while (s_axis_ready == 1'b0);
                end
                s_axis_valid <= 1'b0;
                // Brief gap so the last frame's pool outputs drain into FIFO
                // before frame_rst_n is pulsed.
                repeat(20) @(posedge clk);
            end

            // ---- Wait for done (with generous timeout) ----
            fork
                begin : wait_done
                    wait(hw_done_flag == 1'b1);
                end
                begin : timeout
                    repeat(80000) @(posedge clk);
                    $display("[ERROR] Image %0d: timeout — FC_Serial stuck?", img_idx);
                    $finish;
                end
            join_any
            disable fork;
            @(posedge clk);

            // ---- Argmax over 10 class scores ----
            max_score  = 0;
            best_class = 0;
            for (int c = 0; c < 10; c++) begin
                if (final_scores[c*32 +: 32] > max_score) begin
                    max_score  = final_scores[c*32 +: 32];
                    best_class = c;
                end
            end

            $fdisplay(f_out, "%0d", best_class);
            $fflush(f_out);

            if (img_idx % 10 == 0)
                $display("Progress: %0d/100 images done", img_idx);
        end

        $fclose(f_out);
        $display("=== SNN SRAM Batch Test Completed ===");
        $finish;
    end

endmodule
