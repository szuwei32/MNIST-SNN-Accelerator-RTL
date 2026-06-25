# pre_final_report.tcl — Sourced before final_report.tcl runs PSM analysis.
#
# Re-apply SRAM macro power connections that are not persisted in the ODB
# (add_global_connection rules are not saved across steps).
# Without this, analyze_power_grid throws PSM-0069 on the SRAM vdd/gnd pins.

add_global_connection -net {VDD} -inst_pattern {.*u_macro.*} -pin_pattern {^vdd$} -power
add_global_connection -net {VSS} -inst_pattern {.*u_macro.*} -pin_pattern {^gnd$} -ground
global_connect
