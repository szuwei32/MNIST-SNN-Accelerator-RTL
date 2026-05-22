module LineBuffer #(
  parameter int IMG_WIDTH  = 28,
  parameter int DATA_WIDTH = 8
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  i_valid,
  input  logic [DATA_WIDTH-1:0] i_data,
  output logic                  o_valid,
  output logic [8:0][DATA_WIDTH-1:0] o_window
);

  logic [DATA_WIDTH-1:0] lb0 [0:IMG_WIDTH-1];
  logic [DATA_WIDTH-1:0] lb1 [0:IMG_WIDTH-1];
  logic [DATA_WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7, w8;


  assign o_window[0] = w0; assign o_window[1] = w1; assign o_window[2] = w2;
  assign o_window[3] = w3; assign o_window[4] = w4; assign o_window[5] = w5;
  assign o_window[6] = w6; assign o_window[7] = w7; assign o_window[8] = w8;

  logic [$clog2(IMG_WIDTH)-1:0]   col_cnt;
  logic [$clog2(IMG_WIDTH*2)-1:0] row_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < IMG_WIDTH; i++) begin
        lb0[i] <= 8'd0;
        lb1[i] <= 8'd0;
      end
      w0 <= 0; w1 <= 0; w2 <= 0;
      w3 <= 0; w4 <= 0; w5 <= 0; w6 <= 0; w7 <= 0; w8 <= 0;
      col_cnt <= 0;
      row_cnt <= 0;
      o_valid <= 0;
    end else begin
      
     
      if (i_valid) begin
        // 1. Shift Logic
        for (int i = IMG_WIDTH-1; i > 0; i--) begin
          lb0[i] <= lb0[i-1];
          lb1[i] <= lb1[i-1];
        end
        lb0[0] <= i_data;
        lb1[0] <= lb0[IMG_WIDTH-1];

        // Update Window
        w8 <= i_data;
        w7 <= w8; w6 <= w7;
        w5 <= lb0[IMG_WIDTH-1]; w4 <= w5; w3 <= w4;
        w2 <= lb1[IMG_WIDTH-1]; w1 <= w2; w0 <= w1;

        // 2. Counters Logic
        if (col_cnt == IMG_WIDTH-1) begin
          col_cnt <= 0;
          if (row_cnt < IMG_WIDTH + 2) 
             row_cnt <= row_cnt + 1;
        end else begin
          col_cnt <= col_cnt + 1;
        end

        // 3. Valid Logic (update o_valid)
        if (row_cnt >= 2 && col_cnt >= 2)
          o_valid <= 1;
        else
          o_valid <= 0;
      end else begin 
          o_valid <= 0; 
      end
      
    end
  end

`ifdef FORMAL
    // Formal safety properties — immediate assertions clocked on clk,
    // proven unbounded via SymbiYosys mode prove (k-induction).

    // start verification from a clean reset
    initial assume (!rst_n);

    // col_cnt stays within one row width
    always @(posedge clk)
        if (rst_n) AST_col_in_range: assert (col_cnt < IMG_WIDTH);

    // row_cnt never exceeds the warm-up ceiling
    always @(posedge clk)
        if (rst_n) AST_row_in_range: assert (row_cnt <= IMG_WIDTH + 2);

    // o_valid only goes high after the row warm-up is complete.
    // (Note: o_valid is a registered signal, so col_cnt may already have
    // wrapped to 0 by the cycle o_valid is observed — only the row
    // warm-up condition is a sound same-cycle invariant here.)
    always @(posedge clk)
        if (rst_n) AST_valid_after_warmup: assert (!o_valid || row_cnt >= 2);
`endif

endmodule