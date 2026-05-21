module ConvPE #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 18,
    parameter int V_THRESH   = 59723
) (
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             i_valid,
    input  logic                             i_clear_mem,
    input  logic signed [ACC_WIDTH-1:0]      i_vmem_read,
    input  logic        [8:0][DATA_WIDTH-1:0] i_window,
    input  logic signed [8:0][DATA_WIDTH-1:0] i_weights,
    input  logic                             i_skip,
    output logic                             o_spike,
    output logic                             o_vmem_valid,
    output logic signed [ACC_WIDTH-1:0]      o_vmem_write
);
    logic signed [ACC_WIDTH-1:0] current_sum;
    always_comb begin
        current_sum = 0;
        if (!i_skip) begin
            for (int i = 0; i < 9; i++) begin
                //current_sum = current_sum + ($signed({1'b0, i_window[i]}) * i_weights[i]);
                current_sum = current_sum + ($signed({1'b0, i_window[i]}) * $signed(i_weights[i]));
            end
        end
    end

    logic signed [ACC_WIDTH-1:0] v_mem_current;
    logic signed [ACC_WIDTH-1:0] v_mem_next;
    logic spike_comb;

   always_comb begin
        
        if (i_clear_mem) begin
            v_mem_current = 0; 
        end else begin
            v_mem_current = i_vmem_read >>> 1;
        end

        v_mem_next = v_mem_current + current_sum;
        
        
        spike_comb = (i_valid && ($signed(v_mem_next) >= $signed(V_THRESH)));
        
        if (spike_comb) begin
            v_mem_next = '0; 
        end
    end

    // Gate output registers when the PE has no work to do.
    // Enable = i_valid: covers both the skip case and idle cycles.
    // The async reset path is independent of the gated clock — reset always wins.
    logic clk_pe;
    ClockGate u_cg_pe (.CK(clk), .EN(i_valid), .Q(clk_pe));

    always_ff @(posedge clk_pe or negedge rst_n) begin
        if (!rst_n) begin
            o_spike      <= 1'b0;
            o_vmem_valid <= 1'b0;
            o_vmem_write <= '0;
        end else begin
            o_spike      <= spike_comb;
            o_vmem_valid <= i_valid;
            o_vmem_write <= v_mem_next;
        end
    end

`ifdef FORMAL
    // o_vmem_valid must follow i_valid with exactly 1-cycle pipeline delay
    AST_vmem_valid_lag: assert property (
        @(posedge clk) disable iff (!rst_n)
        i_valid |=> o_vmem_valid)
        else $error("ConvPE: o_vmem_valid did not follow i_valid by 1 cycle");

    // Spike reset: vmem_write must be 0 in the same cycle a spike fires
    AST_spike_clears_vmem: assert property (
        @(posedge clk) disable iff (!rst_n)
        $rose(o_spike) |-> (o_vmem_write == '0))
        else $error("ConvPE: vmem_write not reset to 0 on spike cycle");

    // No X/Z on window pixels when valid is asserted
    AST_no_x_on_window: assert property (
        @(posedge clk) disable iff (!rst_n)
        i_valid |-> !$isunknown(i_window))
        else $error("ConvPE: X/Z detected in window data while i_valid=1");
`endif

endmodule