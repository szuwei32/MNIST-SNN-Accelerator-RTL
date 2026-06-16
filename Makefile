# =============================================================================
# Makefile — MNIST SNN Accelerator
# Targets: train  weights  test-data  compile  sim  verify  formal  clean  all
# =============================================================================

# --- Tool paths --------------------------------------------------------------
IVERILOG   ?= iverilog
VVP        ?= vvp
PYTHON     ?= python3
SBY        ?= sby

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

SIM_TOP = sim/tb_Batch_Test.sv
SIM_BIN = snn_sim

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
	$(IVERILOG) -g2012 -DSIMULATION -o $(SIM_BIN) $(SIM_TOP) $(RTL_SIM)

$(SIM_BIN): $(SIM_TOP) $(RTL_SIM) data/weights_conv.hex data/weights_fc.hex
	$(MAKE) compile

.PHONY: sim
sim: $(SIM_BIN)
	@echo ">>> Running simulation (100 images)..."
	$(VVP) $(SIM_BIN)
	@mkdir -p output
	@cp hw_predictions.txt output/hw_predictions.txt 2>/dev/null || true

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
	@cp -f hw_l1_spikes.txt output/hw_l1_spikes.txt
	@echo ">>> Generating golden references..."
	$(PYTHON) scripts/ref_l1_int.py
	$(PYTHON) scripts/dump_l1_golden.py
	@echo ">>> Comparing..."
	$(PYTHON) scripts/diff_l1.py

# --- Formal verification (SymbiYosys) ----------------------------------------
.PHONY: formal
formal:
	@echo ">>> Running formal verification..."
	$(SBY) -f formal/snn_formal.sby

# --- Utilities ---------------------------------------------------------------
.PHONY: clean
clean:
	@echo ">>> Cleaning generated artifacts..."
	rm -f $(SIM_BIN)
	rm -f data/weights_conv.hex data/weights_fc.hex
	rm -f data/snn_model.pth
	rm -rf data/test_data/
	rm -f hw_predictions.txt hw_l1_spikes.txt
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
	@echo "  make formal     — Run SymbiYosys formal verification"
	@echo "  make clean      — Remove all generated files"
	@echo ""
