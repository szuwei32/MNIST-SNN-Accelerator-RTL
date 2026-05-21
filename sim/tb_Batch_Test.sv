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

    initial begin
        f_out = $fopen("hw_predictions.txt", "w");
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
        $display("=== SNN Batch Testing Completed! ===");
        $finish;
    end
endmodule