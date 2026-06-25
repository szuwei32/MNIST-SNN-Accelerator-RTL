# finish_fixed.tcl — Re-run fill cells and write final DEF from DRC-clean routing
# Uses 5_2_route_fixed.odb (0 DRC violations after TritonRoute repair pass)

read_liberty /OpenROAD-flow-scripts/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty /work/asic/flow/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8_TT_1p8V_25C.lib

read_db /work/asic/flow/orfs_results/5_2_route_fixed.odb
read_sdc /work/asic/flow/orfs_results/5_1_grt.sdc
source /OpenROAD-flow-scripts/flow/platforms/sky130hd/setRC.tcl

puts "=== Placing filler cells ==="
filler_placement "sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8"

puts "=== Writing final DEF and netlist ==="
write_def  /work/asic/flow/orfs_results/6_final_fixed.def
write_verilog /work/asic/flow/orfs_results/6_final_fixed.v
write_db   /work/asic/flow/orfs_results/6_final_fixed.odb

puts "=== Done: 6_final_fixed.def + 6_final_fixed.odb ==="
