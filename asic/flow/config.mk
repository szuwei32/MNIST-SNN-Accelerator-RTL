# =============================================================
# config.mk — OpenROAD Flow Scripts config for SNN Conv Core
# Platform: SKY130HD (130nm)
# =============================================================

export PLATFORM    = sky130hd
export DESIGN_NAME = SNN_Conv_Top

# ----- RTL Sources -------------------------------------------
export VERILOG_FILES = $(DESIGN_DIR)/../src/ClockGate.sv         \
                       $(DESIGN_DIR)/../src/SNN_Conv_Top.sv      \
                       $(DESIGN_DIR)/../src/SNN_Accelerator.sv   \
                       $(DESIGN_DIR)/../src/AvgPooling.sv        \
                       $(DESIGN_DIR)/../src/LineBuffer.sv        \
                       $(DESIGN_DIR)/../src/ConvPE.sv            \
                       $(DESIGN_DIR)/../src/SparsityController.sv \
                       $(DESIGN_DIR)/../src/TimeStep_FSM.sv      \
                       $(DESIGN_DIR)/../src/Vmem_Array.sv

# ----- Constraints -------------------------------------------
export SDC_FILE = $(DESIGN_DIR)/constraint.sdc

# ----- Synthesis ---------------------------------------------
export SYNTH_MEMORY_MAX_BITS = 100000
export SYNTH_HDL_FRONTEND    = slang
export SKIP_CTS_REPAIR_TIMING = 1

# ----- Floorplan ---------------------------------------------
# 500x500 um — conservative starting point for conv core
# If you see "die area too small" errors, increase to 700 700
export DIE_AREA   = 0 0 3000 3000
export CORE_AREA  = 10 10 2990 2990

# ----- Target Clock ------------------------------------------
# Starting at 50 MHz (20 ns) — conservative for first run
# After timing closure, try 15.0 (67 MHz) or 10.0 (100 MHz)
export CLOCK_PERIOD = 20.0

# ----- Placement ---------------------------------------------
# 0.60 = safe starting density; lower to 0.50 if routing fails
export PLACE_DENSITY = 0.60
