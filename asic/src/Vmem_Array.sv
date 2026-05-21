// =============================================================================
// Vmem_Array.sv — Neuron membrane potential distributed RAM
//
// Clock gating: write clock is gated by i_we via ICG.
// When no valid pixel is being processed (i_we=0), the 676×18-bit RAM cells
// see no rising edges → zero dynamic power on ~(1 - duty_cycle) of cycles.
// Estimated saving: ~60–70% of write-path dynamic power across 8 instances.
// =============================================================================
module Vmem_Array #(
    parameter int ACC_WIDTH = 18,
    parameter int MAP_SIZE  = 676
) (
    input  logic                 clk,
    input  logic                 i_we,
    input  logic [9:0]           i_raddr,
    input  logic [9:0]           i_waddr,
    input  logic [ACC_WIDTH-1:0] i_wdata,
    output logic [ACC_WIDTH-1:0] o_rdata
);

    logic [ACC_WIDTH-1:0] ram [0:MAP_SIZE-1];

    // Asynchronous read — same-cycle address lookup
    assign o_rdata = ram[i_raddr];

    // Gated write clock: RAM cells only toggle when a write is pending
    logic clk_w;
    ClockGate u_cg_write (.CK(clk), .EN(i_we), .Q(clk_w));

    always_ff @(posedge clk_w) begin
        ram[i_waddr] <= i_wdata;
    end

endmodule
