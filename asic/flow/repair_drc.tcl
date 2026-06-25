# repair_drc.tcl — Re-run TritonRoute on 5_2_route.odb to fix 12 met1 DRC violations
# All violations: Short/Spacing on met1 near (2753, 2379) um
# Routes are confined to met1-met4 (same as original routing).

read_liberty /OpenROAD-flow-scripts/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty /work/asic/flow/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8_TT_1p8V_25C.lib

read_db /work/asic/flow/orfs_results/5_2_route.odb
read_sdc /work/asic/flow/orfs_results/5_1_grt.sdc
source /OpenROAD-flow-scripts/flow/platforms/sky130hd/setRC.tcl

puts "=== Re-running TritonRoute to fix remaining DRC violations ==="
puts "=== Previous violations: 12 (11 Short + 1 Metal Spacing on met1) ==="

# Re-run detailed route. Routing guides and existing wires are read from the ODB.
# TritonRoute will rip-up-and-reroute the nets with DRC violations.
set_routing_layers -signal met1-met4 -clock met3-met4

detailed_route \
    -output_drc /work/asic/flow/orfs_reports/drc_after_repair.rpt \
    -verbose 1

puts ""
puts "=== DRC after repair ==="
set f [open /work/asic/flow/orfs_reports/drc_after_repair.rpt r]
set violations 0
while {[gets $f line] >= 0} {
    if {[string match "violation type:*" $line]} { incr violations }
}
close $f
puts "Remaining DRC violations: $violations"

write_db /work/asic/flow/orfs_results/5_2_route_fixed.odb
puts "=== Saved: 5_2_route_fixed.odb ==="
