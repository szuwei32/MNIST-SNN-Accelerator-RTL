# MNIST Spiking Neural Network (SNN) Accelerator

A custom RTL implementation of a Spiking Neural Network (SNN) designed for MNIST handwritten digit classification. Built in SystemVerilog, this hardware accelerator achieves **95.00% accuracy** on the test set, matching the bit-accurate PyTorch golden model.

## 💡 Key Features
- **Multiplier-less LIF Neuron**: Replaced the membrane potential decay factor with an arithmetic right shift (`>>>`), eliminating power-hungry hardware multipliers.
- **Sparsity-Aware Computing**: Dynamically detects zero-input windows to skip redundant MAC operations, maximizing energy efficiency.
- **Hardware-Friendly Data Flow**: Utilizes a Channel-Last (HWC) weight permutation and a custom 3x3 `LineBuffer` for real-time spatial convolution.
- **State Retention**: Preserves neuron membrane potentials across $T=16$ time steps using a distributed SRAM array (`Vmem_Array`).

## 🏗️ Architecture

![SNN Accelerator Architecture](workflow.jpg)

## 📂 Repository Structure
- `rtl/`: SystemVerilog source files (PE, Pooling, LineBuffer, FSM, etc.).
- `sim/`: Testbenches for unit and batch testing.
- `scripts/`: Python scripts for PyTorch model training, quantization, and verification.
- `data/`: Extracted INT8 weights (`.hex`) and test images.
- `asic/`: RTL-to-GDSII flow using OpenROAD + SKY130HD 130nm PDK.

## 🔬 ASIC Implementation (SKY130HD)

Full RTL-to-GDSII flow completed with OpenROAD on the SkyWater SKY130HD 130nm PDK.

| Metric | Value |
|--------|-------|
| Achieved Fmax | **62 MHz** (target: 50 MHz) |
| Setup WNS | **+3.88 ns** — 0 violations |
| Core area | **8.875 mm²** @ 62% utilization |
| Total power | **931 mW** |
| DRC violations | **0** |

See [`asic/README.md`](asic/README.md) for full setup instructions and [`asic/reports/6_report.json`](asic/reports/6_report.json) for complete metrics.

## 🚀 Quick Start

### 0. Train model & export weights
python scripts/snn.py
python scripts/export_parameters.py

### 1. Run RTL Simulation
Compile the design and run the 100-image batch test using Icarus Verilog:
```bash
iverilog -g2012 -o snn_sim sim/tb_Batch_Test.sv rtl/*.sv
vvp snn_sim
```

### 2. Verify Accuracy
Compare the hardware predictions against ground truth labels:
```bash
python scripts/verify_hw.py
```