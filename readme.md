# MNIST Spiking Neural Network (SNN) Accelerator

A custom RTL implementation of a Spiking Neural Network (SNN) designed for MNIST handwritten digit classification. Built in SystemVerilog, this hardware accelerator achieves **95% accuracy** on a 100-image hardware simulation batch (PyTorch INT8 baseline; gap due to fixed-point quantization on borderline cases).

## 💡 Key Features
- **Multiplier-less LIF Neuron**: Replaced the membrane potential decay factor with an arithmetic right shift (`>>>`), eliminating power-hungry hardware multipliers.
- **Sparsity-Aware Computing**: Dynamically detects zero-input windows to skip redundant MAC operations, maximizing energy efficiency.
- **Hardware-Friendly Data Flow**: Utilizes a Channel-Last (HWC) weight permutation and a custom 3x3 `LineBuffer` for real-time spatial convolution.
- **State Retention**: Preserves neuron membrane potentials across $T=16$ time steps using a distributed SRAM array (`Vmem_Array`).
- **SRAM-Backed FC Layer**: FC weights stored in 10 × 2 KB OpenRAM SRAM macros, replacing a 108 KB flip-flop array for area efficiency.

## 🏗️ Architecture

![SNN Accelerator Architecture](workflow.jpg)

## 📂 Repository Structure
- `rtl/`: SystemVerilog source files (PE, Pooling, LineBuffer, FSM, etc.).
- `sim/`: Testbenches for unit and batch testing.
- `scripts/`: Python scripts for PyTorch model training, quantization, and verification.
- `data/`: Extracted INT8 weights (`.hex`) and test images.
- `asic/`: RTL-to-GDSII flow using OpenROAD + SKY130HD 130nm PDK.

## 🔬 ASIC Implementation (SKY130HD)

Full RTL-to-GDSII implementation flow completed with OpenROAD on the SkyWater SKY130HD 130nm PDK. Two designs were taken through P&R: the **Conv+Pool core** (used for clock-gating ablation) and the **full system** including the SRAM-backed FC layer.

---

### Full System — `Top_System_SRAM` (Conv + Pool + SRAM FC)

| Metric | Value |
|--------|-------|
| Target clock | **40 MHz** (25 ns) |
| Setup WNS (post-route SPEF) | **+1.033 ns** — 0 violations |
| Die area | **4000 × 4000 µm (16 mm²)** |
| Core utilization (post-CTS) | **63%** |
| SRAM macros | 10 × `sky130_sram_1rw1r_64x256_8` (2 KB each, 20 KB total) |
| Routing DRC violations | **0** |

Critical path: clock-gating check on `ConvPE` ICG enable (`u_cg_pe.en_latch`). Timing is clean at 40 MHz (WNS +1.033 ns); violated at 50 MHz (−1.467 ns) and 45 MHz (−0.467 ns).

---

### Conv+Pool Core — `SNN_Conv_Top` (Clock-Gating Ablation)

Two full RTL-to-GDSII runs with **identical** PDK, floorplan and constraints —
the only difference is `ClockGate.sv` (latch ICG vs. a `Q = CK` passthrough):

| Metric | without ICG | with ICG | Delta |
|--------|-------------|----------|-------|
| Total power (estimated) | 1050 mW | **453 mW** | **−56.8%** |
| — internal (clock-pin) | 622 mW | 182 mW | −70.9% |
| — switching | 429 mW | 272 mW | −36.6% |
| Fmax | 59.3 MHz | 57.5 MHz | −1.8 MHz |
| Setup WNS @ 50 MHz | +3.14 ns | +2.61 ns | — |
| Routing DRC | 0 | 0 | both clean |

ICG cuts total power 56.8%; internal power drops the most (−70.9%) because idle
registers' clock pins stop toggling. The 1.8 MHz Fmax cost is the ICG latch
insertion delay — a normal power/timing trade-off.

> Power figures are OpenROAD post-route estimates at default activity factors (not silicon measurement). The comparison is valid since both runs use identical conditions.

Reports: [`asic/reports/6_report_icg.json`](asic/reports/6_report_icg.json), [`asic/reports/6_report_noicg.json`](asic/reports/6_report_noicg.json).

---

## 💡 RTL/ASIC Design Highlights
- **Clock Gating**: Explicit ICG cells (`rtl/cells/ClockGate.sv`) on Vmem write-path (8 × 676 FFs) and ConvPE output registers — zero dynamic power when idle
- **DFT Ready**: `scan_en / scan_in / scan_out` ports on `Top_System` for ATPG scan-chain insertion
- **Formal Verification**: 6 safety properties on LineBuffer and TimeStep_FSM control logic, proven by SymbiYosys k-induction (`make formal`)
- **Bit-Exact Datapath Check**: RTL matches an INT8 fixed-point golden reference **end-to-end** — layer-1 spikes (**100%** over 8.65M neuron outputs) and final class scores (**100%** across all 100 images) — via `make verify-l1`
- **AXI4-Lite Wrapper**: `SNN_AXI_Wrapper.sv` packages the accelerator as a drop-in SoC IP block
- **Pipelined FC MAC**: 1-cycle pipeline register breaks the 80-multiply combinatorial path in FullyConnected

## 🚀 Quick Start

```bash
make verify   # train → export weights → compile → simulate → check accuracy
make verify-l1 # bit-exact check: RTL L1 spikes + final scores vs INT8 golden
make formal   # run SymbiYosys formal verification (requires sby)
make clean    # remove all generated artifacts
make help     # show all targets
```

### Manual flow
```bash
# 1. Train model and export quantized weights
python3 scripts/snn.py
python3 scripts/export_parameters.py

# 2. Compile RTL (iverilog 12+)
iverilog -g2012 -DSIMULATION -o snn_sim \
  sim/tb_Batch_Test.sv \
  rtl/cells/ClockGate.sv \
  rtl/top/SNN_Accelerator.sv rtl/top/Top_System.sv \
  rtl/core/*.sv rtl/memory/*.sv

# 3. Run simulation and verify accuracy
vvp snn_sim
python3 scripts/verify_hw.py

# 4. Formal verification (install SymbiYosys first)
# conda install -c litex-hub symbiyosys bitwuzla
sby -f formal/snn_formal.sby
```
