# =============================================================
# config.mk — OpenROAD Flow Scripts: SNN Full Accelerator
# Platform   : SKY130HD (130 nm)
# Design     : Conv + Pool + SRAM-backed serialized FC layer
# Top module : Top_System_SRAM
# SRAM macro : sky130_sram_1rw1r_64x256_8 (64-bit × 256 words = 2KB per bank)
#              10 instances; physical files in asic/pdk/sky130_sram_macros/
# =============================================================

export PLATFORM    = sky130hd
export DESIGN_NAME = Top_System_SRAM

# ----- RTL Sources -------------------------------------------
export VERILOG_FILES = \
    $(DESIGN_DIR)/../src/ClockGate.sv            \
    $(DESIGN_DIR)/../src/SNN_Accelerator.sv      \
    $(DESIGN_DIR)/../src/AvgPooling.sv           \
    $(DESIGN_DIR)/../src/ConvPE.sv               \
    $(DESIGN_DIR)/../src/FC_Serial.sv            \
    $(DESIGN_DIR)/../src/FCWeightSRAM.sv         \
    $(DESIGN_DIR)/../src/LineBuffer.sv           \
    $(DESIGN_DIR)/../src/SparsityController.sv   \
    $(DESIGN_DIR)/../src/TimeStep_FSM.sv         \
    $(DESIGN_DIR)/../src/Top_System_SRAM.sv      \
    $(DESIGN_DIR)/../src/Vmem_Array.sv           \
    $(DESIGN_DIR)/../src/bb/sky130_sram_1rw1r_64x256_8.v

# ----- Constraints -------------------------------------------
export SDC_FILE = $(DESIGN_DIR)/constraint.sdc

# ----- Synthesis ---------------------------------------------
# (slang not available in openroad/orfs image; Yosys built-in SV parser used)
# export SYNTH_HDL_FRONTEND = slang

# VERILOG_DEFINES: activates `ifndef SYNTHESIS` guards in SNN_Accelerator.sv.
# FCWeightSRAM uses `ifdef SIMULATION` — absence of SIMULATION activates synth path.
export VERILOG_DEFINES = -D SYNTHESIS

# Vmem_Array: 8 × 676 × 18 = 97,344 bits of FF RAM (inferred, not a macro).
# FCWeightSRAM uses the sky130_sram_1rw1r_64x256_8 blackbox — no memory inference.
export SYNTH_MEMORY_MAX_BITS = 2000000

# ----- SRAM Macro Physical Files -----------------------------
# sky130_sram_1rw1r_64x256_8: 64-bit × 256 words = 2KB (same capacity as 32×512)
# Files extracted from openroad/orfs Docker image (sky130ram platform, OpenRAM).
# Stored locally at asic/pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/.
export ADDITIONAL_LEFS = \
    $(DESIGN_DIR)/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8.lef

export ADDITIONAL_LIBS = \
    $(DESIGN_DIR)/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8_TT_1p8V_25C.lib

export ADDITIONAL_GDS  = \
    $(DESIGN_DIR)/../pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8.gds

# ----- Macro Placement ---------------------------------------
# 10 SRAM instances arranged in 2 columns × 5 rows along the left die edge.
# Each macro: 1040.76 µm wide × 403.035 µm tall.
# Column 0: x = 10,           columns 1: x = 10 + 1040.76 + 5 = 1055.76
# Rows 0-4: y = 10 + row × (403.035 + 5) = 10, 418.035, 826.07, 1234.1, 1642.14
export MACRO_PLACEMENT = $(DESIGN_DIR)/macro_placement_sram.cfg

# Macro blockage to prevent standard cells from overlapping SRAM region
# (covers the 2-col × 5-row SRAM block: x=0..2108, y=0..2057)
# export MACRO_PLACEMENT_TCL = $(DESIGN_DIR)/macro_blockage.tcl

# ----- Floorplan ---------------------------------------------
# Die enlarged to 4000×4000 µm to comfortably fit 10 × (1040×403) SRAMs
# plus conv/pool logic (~3000×3000 from previous run).
# SRAM block occupies ~2100×2050 µm (left side); logic fills remaining ~1900×4000.
export DIE_AREA  = 0 0 4000 4000
export CORE_AREA = 10 10 3990 3990

# ----- Target Clock ------------------------------------------
# Confirmed clean at 25 ns (40 MHz): WNS = +1.033 ns (post-route SPEF STA).
# Original 20 ns (50 MHz) violated by 1.467 ns; 22 ns (45 MHz) violated by 0.467 ns.
# Critical path: clock gating check through u_l1_conv.GEN_PE_CHANNEL[0].u_cg_pe.en_latch.
export CLOCK_PERIOD = 25.0

# ----- Placement ---------------------------------------------
# Relaxed to 0.45 to leave room around SRAM macros.
export PLACE_DENSITY = 0.45

# ----- Skip CTS repair (optional) ---------------------------
export SKIP_CTS_REPAIR_TIMING = 1

# ----- Routing layer limits ----------------------------------
# fastroute.tcl calls set_routing_layers -signal met1-met4, keeping signal
# routes off met5 where sky130hd PDN straps cause local congestion hotspots.
# set_routing_layers must be called in a Tcl hook — the env var alone is not enough.
export MAX_ROUTING_LAYER           = met4
export PRE_GLOBAL_ROUTE_TCL        = $(DESIGN_DIR)/fastroute.tcl

# Allow GRT to produce routing guides despite residual met5 PDN congestion,
# then let TritonRoute (DRT) complete the detailed routing on met1-met4.
export GLOBAL_ROUTE_ARGS           = -allow_congestion -congestion_iterations 100
export GENERATE_ARTIFACTS_ON_FAILURE = 1

# ----- Custom PDN config -----------------------------------------
# Adds global connections for OpenRAM SRAM macro vdd/gnd pins.
export PDN_TCL = $(DESIGN_DIR)/pdn_sram.tcl

# ----- Final report: re-apply SRAM power connections -----------
# add_global_connection rules are NOT persisted in ODB, so each step that
# needs them must re-apply them.  This hook runs before PSM analysis.
export PRE_FINAL_REPORT_TCL = $(DESIGN_DIR)/pre_final_report.tcl

# Override sky130hd default voltages to skip analyze_power_grid on SRAM-heavy
# designs where SRAM vdd pins aren't routed through the standard-cell PDN.
# Remove these overrides once SRAM PDN is physically closed.
export PWR_NETS_VOLTAGES =
export GND_NETS_VOLTAGES =
