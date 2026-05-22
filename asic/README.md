# ASIC Implementation — SNN Conv Core

RTL-to-GDS flow using OpenROAD + SKY130 130nm PDK.

## What's in here

```
asic/
├── src/                      # Synthesis-ready RTL
│   ├── SNN_Conv_Top.sv       # Top wrapper (Conv + Pool)
│   ├── SNN_Accelerator.sv    # $readmemh replaced with localparam ROM
│   ├── AvgPooling.sv         # Unchanged from rtl/
│   ├── LineBuffer.sv         # Unchanged
│   ├── ConvPE.sv             # Unchanged
│   ├── SparsityController.sv # Unchanged
│   ├── TimeStep_FSM.sv       # Unchanged
│   └── Vmem_Array.sv         # Unchanged
├── flow/
│   ├── config.mk             # OpenROAD flow config
│   └── constraint.sdc        # SDC timing constraints
└── scripts/
    └── gen_weights.py        # Converts weights_conv.hex → localparam
```

## Why FC layer is excluded

`FullyConnected.sv` requires 13,520 × 8-bit weights (≈108 KB).
FPGA tools automatically map this to Block RAM.
Standard-cell ASIC synthesis has no equivalent — an SRAM macro
(OpenRAM / DFFRAM) would be required, which is a separate flow.
The Conv+Pool core represents the novel hardware design.

## Implementation Results

Complete RTL-to-GDSII run on SKY130HD with OpenROAD flow scripts. The design
uses latch-based ICG clock gating on the `Vmem_Array` write path and `ConvPE`
output registers.

| Metric | Value (with ICG) |
|--------|------------------|
| Target clock | 50 MHz (20 ns) |
| Setup WNS | **+2.61 ns** (0 violations) |
| Hold WNS | **+0.12 ns** (0 violations) |
| Fmax | **57.5 MHz** |
| Core area | **8.875 mm²** (3000×3000 µm die, 62% utilization) |
| Total power | **453 mW** |
| Routing DRC violations | **0** |
| Sequential cells | 125,349 |

Full metrics: [`reports/6_report_icg.json`](reports/6_report_icg.json)

### Clock-gating ablation

Two full RTL-to-GDSII runs with **identical** PDK, floorplan and constraints —
the only difference is `ClockGate.sv` (latch ICG vs. a `Q = CK` passthrough):

| Metric | without ICG | with ICG | Delta |
|--------|-------------|----------|-------|
| Total power | 1050 mW | 453 mW | **−56.8%** |
| — internal (clock-pin) | 622 mW | 182 mW | −70.9% |
| — switching | 429 mW | 272 mW | −36.6% |
| Fmax | 59.3 MHz | 57.5 MHz | −1.8 MHz |
| Setup WNS @ 50 MHz | +3.14 ns | +2.61 ns | −0.53 ns |
| Routing DRC | 0 | 0 | both clean |

ICG cuts total power 56.8%; internal power drops the most (−70.9%) because idle
registers' clock pins stop toggling. The 1.8 MHz Fmax cost is the ICG latch
insertion delay — a normal power/timing trade-off. Reports:
[`reports/6_report_icg.json`](reports/6_report_icg.json),
[`reports/6_report_noicg.json`](reports/6_report_noicg.json).
Full flow write-up: [`synthesisprogress.md`](synthesisprogress.md).

> **Note on die size**: The Conv+Pool core uses 8× `Vmem_Array` instances
> (676×18-bit flip-flop RAM each), expanding to ~193K cells after synthesis.
> A 3000×3000 µm die is required; the original 500×500 µm placeholder is too small.

## Setup steps

### 1. Weights and RTL

Conv weights are already hardcoded as `localparam` in `asic/src/SNN_Accelerator.sv` —
no need to run `gen_weights.py` unless you retrain the model.

Copy unchanged RTL from `rtl/` to `asic/src/`:

```bash
cp rtl/core/AvgPooling.sv         asic/src/
cp rtl/core/ConvPE.sv             asic/src/
cp rtl/core/LineBuffer.sv         asic/src/
cp rtl/core/SparsityController.sv asic/src/
cp rtl/core/TimeStep_FSM.sv       asic/src/
cp rtl/memory/Vmem_Array.sv       asic/src/
```

### 2. Run OpenROAD flow (Docker)

```bash
# Clone ORFS (shallow)
git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git

# Pull the Docker image
docker pull openroad/flow-ubuntu22.04-builder:latest

# Copy design files into ORFS tree
mkdir -p OpenROAD-flow-scripts/flow/designs/sky130hd/snn_conv
cp -r asic/* OpenROAD-flow-scripts/flow/designs/sky130hd/snn_conv/

# Run full flow (non-interactive)
docker run --rm --platform linux/amd64 \
  --security-opt seccomp=unconfined \
  -v $(pwd)/OpenROAD-flow-scripts/flow/designs/sky130hd/snn_conv:/OpenROAD-flow-scripts/flow/designs/sky130hd/snn_conv \
  -w /OpenROAD-flow-scripts/flow \
  openroad/flow-ubuntu22.04-builder:latest \
  bash -c "make DESIGN_CONFIG=./designs/sky130hd/snn_conv/flow/config.mk synth floorplan place cts route finish 2>&1"
```

> **CPU note**: `openroad/flow-ubuntu22.04-builder:latest` requires AVX2.
> On pre-Zen2 / pre-Haswell CPUs, use an older image tag.
> `SKIP_CTS_REPAIR_TIMING = 1` is set in `config.mk` to work around a
> `detailed_placement` SIGILL on Zen2 hosts during the CTS timing-repair loop;
> remove it if your CPU supports the required instruction set.

### 3. Read results

```bash
# All metrics in one file
cat logs/sky130hd/SNN_Conv_Top/base/6_report.json | python3 -m json.tool

# Key numbers
python3 -c "
import json
d = json.load(open('logs/sky130hd/SNN_Conv_Top/base/6_report.json'))
print('Fmax:       ', d['finish__timing__fmax']/1e6, 'MHz')
print('Setup WNS:  ', d['finish__timing__setup__ws'], 'ns')
print('Hold WNS:   ', d['finish__timing__hold__ws'], 'ns')
print('Core area:  ', d['finish__design__core__area']/1e6, 'mm²')
print('Power:      ', d['finish__power__total'], 'W')
"
```
