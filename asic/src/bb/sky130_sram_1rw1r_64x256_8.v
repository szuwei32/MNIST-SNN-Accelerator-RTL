// Yosys blackbox stub for sky130_sram_1rw1r_64x256_8
// Source: openroad/orfs Docker image (sky130ram platform, OpenRAM-generated)
// Physical files: asic/pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/
//
// Port 0 (RW): clk0, csb0, web0, wmask0[7:0], addr0[7:0], din0[63:0], dout0[63:0]
// Port 1 (R):  clk1, csb1,                    addr1[7:0],              dout1[63:0]
(* blackbox *)
module sky130_sram_1rw1r_64x256_8 (
    // Port 0: read-write
    input         clk0,
    input         csb0,
    input         web0,
    input  [7:0]  wmask0,
    input  [7:0]  addr0,
    input  [63:0] din0,
    output [63:0] dout0,
    // Port 1: read-only
    input         clk1,
    input         csb1,
    input  [7:0]  addr1,
    output [63:0] dout1
);
endmodule
