# sta_check.tcl — Post-route STA at multiple clock periods
# Reads 6_final.odb + 6_final.spef (post-route OpenRCX parasitics)

read_liberty /OpenROAD-flow-scripts/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty /work/asic/flow/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8_TT_1p8V_25C.lib

read_db /work/asic/flow/orfs_results/6_final.odb

# Load parasitics extracted by OpenRCX
read_spef /work/asic/flow/orfs_results/6_final.spef

# Base constraints (input/output delays etc.)
read_sdc /work/asic/flow/orfs_results/6_final.sdc

set_propagated_clock [all_clocks]

foreach period {20.0 22.0 25.0 30.0} {
    # Override clock period — create_clock on the same port replaces the old clock
    set half [expr {$period / 2.0}]
    create_clock -name clk -period $period -waveform [list 0 $half] [get_ports clk]
    set_propagated_clock [all_clocks]

    set freq_mhz [expr {int(1000.0 / $period)}]
    report_wns
    report_tns
    set wns [sta::worst_slack -max]
    puts "=== ${period} ns (${freq_mhz} MHz)  WNS=[format %.3f $wns] ns ==="
    if { $wns >= 0.0 } {
        puts "    TIMING CLEAN"
    } else {
        puts "    Violated by [format %.3f [expr {-$wns}]] ns"
    }
    puts ""
}

# Full path report at 25 ns
puts "==========================================="
puts "Critical path at 25.0 ns (40 MHz):"
puts "==========================================="
create_clock -name clk -period 25.0 -waveform {0 12.5} [get_ports clk]
set_propagated_clock [all_clocks]
report_checks -path_delay max -format full_clock_expanded \
    -fields {slew cap input_pins} -no_line_splits -group_count 1
