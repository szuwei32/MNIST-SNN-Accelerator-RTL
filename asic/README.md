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

Obtained from a complete RTL-to-GDSII run on SKY130HD using OpenROAD flow scripts.
**Latest run includes clock gating** (ICG cells on Vmem_Array write path + ConvPE output FFs).

| Metric | Value |
|--------|-------|
| Target clock | 50 MHz (20 ns) |
| Achieved Fmax | **59 MHz** |
| Setup WNS | **+2.12 ns** (0 violations) |
| Hold WNS | **+0.01 ns** (0 violations) |
| Core area | **8.875 mm²** (3000×3000 µm die, 62% utilization) |
| Total power | **452 mW** ← down from 931 mW (−51%) with clock gating |
| DRC violations | **0** |
| Total std cells | 362,933 (125,349 sequential) |

Full metrics: [`asic/reports/6_report_clockgating.json`](reports/6_report_clockgating.json)

> **Clock gating impact**: ICG cells gate the write clock of 8× Vmem_Array instances
> (8 × 676 × 18-bit FFs) and ConvPE output registers. When no pixel is being processed,
> these FFs see no rising edges — zero dynamic power. Total power dropped 51% with
> negligible area overhead. Fmax reduced slightly (62→59 MHz) due to ICG latch delay.
>
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
