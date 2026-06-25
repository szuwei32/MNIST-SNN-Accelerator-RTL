# =============================================================================
# Makefile — MNIST SNN Accelerator
# Targets: train  weights  test-data  compile  sim  verify  formal  clean  all
#          compile-sram  sim-sram  verify-sram
# =============================================================================

# --- Tool paths --------------------------------------------------------------
IVERILOG   ?= iverilog
VVP        ?= vvp
PYTHON     ?= python3
CONDA_BIN  := /data2/william/conda/envs/snn-accelerator/bin
export PATH := $(CONDA_BIN):$(PATH)
SBY        ?= $(CONDA_BIN)/sby

# --- Sources -----------------------------------------------------------------
RTL_SIM = rtl/cells/ClockGate.sv       \
          rtl/top/SNN_Accelerator.sv   \
          rtl/top/Top_System.sv        \
          rtl/core/AvgPooling.sv       \
          rtl/core/ConvPE.sv           \
          rtl/core/FullyConnected.sv   \
          rtl/core/LineBuffer.sv       \
          rtl/core/SparsityController.sv \
          rtl/core/TimeStep_FSM.sv     \
          rtl/memory/Vmem_Array.sv

SIM_TOP  = sim/tb_Batch_Test.sv
BUILD    = build
SIM_BIN  = $(BUILD)/snn_sim

# --- Default target ----------------------------------------------------------
.PHONY: all
all: verify

# --- ML flow -----------------------------------------------------------------
.PHONY: train
train:
	@echo ">>> Training SNN model..."
	$(PYTHON) scripts/snn.py

.PHONY: weights
weights: data/snn_model.pth
	@echo ">>> Exporting quantized weights to data/..."
	$(PYTHON) scripts/export_parameters.py

data/snn_model.pth:
	$(MAKE) train

data/weights_conv.hex data/weights_fc.hex: data/snn_model.pth
	$(MAKE) weights

.PHONY: test-data
test-data: data/snn_model.pth
	@echo ">>> Exporting test images and labels to data/test_data/ ..."
	$(PYTHON) scripts/export_test_data.py

# --- RTL simulation ----------------------------------------------------------
.PHONY: compile
compile: data/weights_conv.hex data/weights_fc.hex
	@echo ">>> Compiling RTL..."
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -DSIMULATION -o $(SIM_BIN) $(SIM_TOP) $(RTL_SIM)

$(SIM_BIN): $(SIM_TOP) $(RTL_SIM) data/weights_conv.hex data/weights_fc.hex
	$(MAKE) compile

.PHONY: sim
sim: $(SIM_BIN) test-data
	@echo ">>> Running simulation (100 images)..."
	$(VVP) $(SIM_BIN)
	@mkdir -p output
	@mv -f hw_predictions.txt output/hw_predictions.txt 2>/dev/null || true

.PHONY: verify
verify: sim
	@echo ">>> Verifying hardware accuracy..."
	$(PYTHON) scripts/verify_hw.py

# --- L1 spike bit-exact verification -----------------------------------------
# Dumps the RTL layer-1 spike train and checks it against (1) a bit-exact INT8
# fixed-point reference (must be 100%) and (2) the float PyTorch golden.
.PHONY: verify-l1
verify-l1: $(SIM_BIN)
	@echo ">>> Dumping RTL L1 spikes..."
	$(VVP) $(SIM_BIN) +DUMP_L1
	@mkdir -p output
	@mv -f hw_l1_spikes.txt output/hw_l1_spikes.txt
	@mv -f hw_scores.txt output/hw_scores.txt
	@echo ">>> Generating golden references..."
	$(PYTHON) scripts/ref_l1_int.py
	$(PYTHON) scripts/ref_pipeline_int.py
	$(PYTHON) scripts/dump_l1_golden.py
	@echo ">>> Comparing..."
	$(PYTHON) scripts/diff_l1.py

# --- SRAM-friendly FC flow (FC_Serial + Top_System_SRAM) ---------------------
# Shared golden RTL comes from rtl/; ASIC/SRAM-specific files come from asic/src/.
RTL_SRAM = rtl/cells/ClockGate.sv             \
           rtl/top/SNN_Accelerator.sv         \
           asic/src/Top_System_SRAM.sv        \
           rtl/core/AvgPooling.sv             \
           rtl/core/ConvPE.sv                 \
           asic/src/FC_Serial.sv              \
           rtl/core/LineBuffer.sv             \
           rtl/core/SparsityController.sv     \
           rtl/core/TimeStep_FSM.sv           \
           asic/src/FCWeightSRAM.sv           \
           rtl/memory/Vmem_Array.sv

SIM_SRAM_TOP = asic/sim/tb_Batch_Test_SRAM.sv
SIM_SRAM_BIN = $(BUILD)/snn_sim_sram

.PHONY: compile-sram
compile-sram: data/weights_conv.hex data/weights_fc.hex
	@echo ">>> Compiling SRAM-friendly RTL..."
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -DSIMULATION -o $(SIM_SRAM_BIN) $(SIM_SRAM_TOP) $(RTL_SRAM)

$(SIM_SRAM_BIN): $(SIM_SRAM_TOP) $(RTL_SRAM) data/weights_conv.hex data/weights_fc.hex
	$(MAKE) compile-sram

.PHONY: sim-sram
sim-sram: $(SIM_SRAM_BIN) test-data
	@echo ">>> Running SRAM simulation (100 images)..."
	$(VVP) $(SIM_SRAM_BIN)
	@mkdir -p output
	@mv -f hw_predictions_sram.txt output/hw_predictions_sram.txt 2>/dev/null || true

.PHONY: verify-sram
verify-sram: sim-sram
	@echo ">>> Verifying SRAM FC accuracy..."
	@$(PYTHON) -c "\
gt  = [int(l) for l in open('output/test_labels.txt')  if l.strip()]; \
pr  = [int(l) for l in open('output/hw_predictions_sram.txt') if l.strip()]; \
n   = min(len(gt), len(pr)); \
ok  = sum(g == p for g, p in zip(gt[:n], pr[:n])); \
print('========================================'); \
print('   SNN SRAM Accelerator Final Report   '); \
print('========================================'); \
print(f'Total Images Tested : {n}'); \
print(f'Correct Predictions : {ok}'); \
print(f'Hardware Accuracy   : {ok/n*100:.2f}%'); \
print('========================================')"

# --- Formal verification (SymbiYosys) ----------------------------------------
.PHONY: formal
formal:
	@echo ">>> Running formal verification..."
	$(SBY) -f formal/snn_formal.sby

# --- ASIC synthesis (OpenROAD Flow Scripts via Docker) -----------------------
# Runs Yosys synthesis only (step 1_synth).  Place-and-route is BLOCKED until
# SKY130 SRAM macro LEF/LIB/GDS files are downloaded — see asic/flow/config.mk.
#
# Prerequisites:
#   docker pull openroad/flow-scripts   (or openroad/flow:latest)
#   git clone https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts \
#       $(ORFS_ROOT)
#
# Usage:
#   ORFS_ROOT=<path-to-OpenROAD-flow-scripts> make asic-synth
#
ORFS_IMAGE_SYNTH ?= openroad/flow-ubuntu22.04-dev   # Yosys only (no OpenROAD binary)
ORFS_IMAGE_PNR   ?= openroad/orfs                   # Full ORFS: Yosys + OpenROAD P&R
ORFS_IMAGE       ?= $(ORFS_IMAGE_PNR)               # Default: full image
ORFS_WORK_DIR     = /work
ORFS_CFG          = $(ORFS_WORK_DIR)/asic/flow/config.mk
ORFS_RESULTS      = $(ORFS_WORK_DIR)/asic/flow/orfs_results
ORFS_LOGS         = $(ORFS_WORK_DIR)/asic/flow/orfs_logs
ORFS_REPORTS      = $(ORFS_WORK_DIR)/asic/flow/orfs_reports
ORFS_RUN          = docker run --rm \
                      -v $(abspath .):/work \
                      $(ORFS_IMAGE) \
                      bash -c 'export PATH=/OpenROAD-flow-scripts/tools/install/OpenROAD/bin:$$PATH; \
                               cd /OpenROAD-flow-scripts/flow && make \
                               DESIGN_CONFIG=$(ORFS_CFG) \
                               RESULTS_DIR=$(ORFS_RESULTS) \
                               LOG_DIR=$(ORFS_LOGS) \
                               REPORTS_DIR=$(ORFS_REPORTS)'

.PHONY: asic-synth
asic-synth:
	@echo ">>> ORFS synthesis (Top_System_SRAM, SKY130HD)..."
	@mkdir -p asic/flow/orfs_results asic/flow/orfs_logs asic/flow/orfs_reports
	$(ORFS_RUN) synth 2>&1 | tee asic/flow/orfs_synth.log

.PHONY: asic-floorplan
asic-floorplan: asic-synth
	@echo ">>> ORFS floorplan..."
	$(ORFS_RUN) floorplan 2>&1 | tee asic/flow/orfs_floorplan.log

.PHONY: asic-place
asic-place: asic-floorplan
	@echo ">>> ORFS placement..."
	$(ORFS_RUN) place 2>&1 | tee asic/flow/orfs_place.log

.PHONY: asic-cts
asic-cts: asic-place
	@echo ">>> ORFS CTS..."
	$(ORFS_RUN) cts 2>&1 | tee asic/flow/orfs_cts.log

.PHONY: asic-route
asic-route: asic-cts
	@echo ">>> ORFS global + detailed route..."
	$(ORFS_RUN) route 2>&1 | tee asic/flow/orfs_route.log

.PHONY: asic-finish
asic-finish: asic-route
	@echo ">>> ORFS finish (GDS + timing report)..."
	$(ORFS_RUN) finish 2>&1 | tee asic/flow/orfs_finish.log

.PHONY: asic-pnr
asic-pnr:
	@echo ">>> ORFS full P&R flow (synth → finish)..."
	@mkdir -p asic/flow/orfs_results asic/flow/orfs_logs asic/flow/orfs_reports
	$(ORFS_RUN) finish 2>&1 | tee asic/flow/orfs_pnr.log

.PHONY: asic-synth-conv
asic-synth-conv:
	@echo ">>> ORFS synthesis (SNN_Conv_Top, Conv+Pool only)..."
	docker run --rm \
	    -v $(abspath .):/work \
	    openroad/flow-ubuntu22.04-dev \
	    bash -c "cd /work && yosys asic/flow/synth_conv.ys" \
	| tee asic/flow/synth_conv.log

# --- Utilities ---------------------------------------------------------------
.PHONY: clean
clean:
	@echo ">>> Cleaning generated artifacts..."
	rm -rf $(BUILD)/
	rm -f data/weights_conv.hex data/weights_fc.hex
	rm -f data/snn_model.pth
	rm -rf data/test_data/
	rm -f hw_predictions.txt hw_predictions_sram.txt hw_l1_spikes.txt hw_scores.txt
	rm -rf output/
	find . -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

.PHONY: help
help:
	@echo ""
	@echo "MNIST SNN Accelerator — Available targets:"
	@echo "  make train      — Train PyTorch SNN model (saves to data/snn_model.pth)"
	@echo "  make weights    — Export quantized weights to data/*.hex"
	@echo "  make test-data  — Export 100 test images to data/test_data/ + labels"
	@echo "  make compile    — Compile RTL with iverilog"
	@echo "  make sim        — Run 100-image batch simulation"
	@echo "  make verify     — Full flow: sim + accuracy check  (default: make all)"
	@echo "  make verify-l1  — Bit-exact L1 spike check vs INT8 + float goldens"
	@echo "  make compile-sram — Compile ASIC/SRAM-friendly RTL (asic/src/)"
	@echo "  make sim-sram   — Run 100-image batch with SRAM FC (asic/sim/)"
	@echo "  make verify-sram  — SRAM flow: sim + accuracy check"
	@echo "  make formal     — Run SymbiYosys formal verification"
	@echo "  make clean      — Remove all generated files"
	@echo ""
