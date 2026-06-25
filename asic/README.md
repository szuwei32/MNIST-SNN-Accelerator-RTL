# ASIC Implementation — SNN Accelerator (SKY130HD)

RTL-to-GDS flow using OpenROAD + SKY130 130nm PDK. Two designs were implemented:
the **Conv+Pool core** (`SNN_Conv_Top`) for the clock-gating ablation study, and the
**full system** (`Top_System_SRAM`) including the SRAM-backed FC layer.

## What's in here

```
asic/
├── src/                         # Synthesis-ready RTL
│   ├── Top_System_SRAM.sv       # Full system top (Conv + Pool + SRAM FC)
│   ├── SNN_Conv_Top.sv          # Conv+Pool core (ablation target)
│   ├── FC_Serial.sv             # Serialized FC accumulator (reads from SRAM)
│   ├── FCWeightSRAM.sv          # SRAM arbiter / read controller
│   ├── FC_SRAM_Loader.sv        # Weight loader
│   ├── SNN_Accelerator.sv       # Conv core (localparam weights)
│   ├── AvgPooling.sv
│   ├── ConvPE.sv
│   ├── LineBuffer.sv
│   ├── SparsityController.sv
│   ├── TimeStep_FSM.sv
│   ├── Vmem_Array.sv
│   ├── ClockGate.sv
│   └── bb/sky130_sram_1rw1r_64x256_8.v   # SRAM blackbox
├── flow/
│   ├── config.mk                # Full-system P&R config (Top_System_SRAM)
│   ├── constraint.sdc
│   ├── fastroute.tcl            # Restricts signal routing to met1-met4
│   ├── pdn_sram.tcl             # PDN + SRAM global connections
│   └── pre_final_report.tcl     # Re-applies SRAM power connections before PSM
├── pdk/
│   └── sky130_sram_macros/
│       └── sky130_sram_1rw1r_64x256_8/  # LEF/LIB/GDS/v for SRAM macro
├── reports/
│   ├── 6_report_icg.json        # Conv+Pool P&R with ICG
│   └── 6_report_noicg.json      # Conv+Pool P&R without ICG
└── scripts/
    └── gen_weights.py
```

---

## Full System — `Top_System_SRAM`

Complete RTL-to-GDSII for the full accelerator: Conv (8 filters) + Avg Pool + serialized FC backed by 10 × 2 KB SRAM macros.

| Metric | Value |
|--------|-------|
| Target clock | **40 MHz** (25 ns period) |
| Setup WNS (post-route SPEF STA) | **+1.033 ns** — 0 violations |
| Die area | **4000 × 4000 µm (16 mm²)** |
| Core utilization (post-CTS) | **63%** |
| SRAM macros | 10 × `sky130_sram_1rw1r_64x256_8` (64-bit × 256 words = 2 KB each) |
| Routing DRC violations | **0** (after TritonRoute repair pass) |

Critical path: ICG enable signal in `ConvPE` clock gate (`u_cg_pe.en_latch`). Clean at 40 MHz (WNS +1.033 ns); violated at 50 MHz (−1.467 ns) and 45 MHz (−0.467 ns).

### Key implementation challenges

**met5 routing congestion**: sky130hd PDN places power straps on met5, saturating the layer for signal routes. Fixed by creating `fastroute.tcl` to call `set_routing_layers -signal met1-met4`. Setting `MAX_ROUTING_LAYER` in the environment variable alone is insufficient — the `set_routing_layers` Tcl call must be made in a pre-GRT hook.

**SRAM PDN connectivity**: OpenRAM macro `vdd`/`gnd` pins are not connected through the standard-cell PDN ring. `add_global_connection` rules are not persisted in the ODB across steps, so they must be re-applied in a `PRE_FINAL_REPORT_TCL` hook before PSM analysis.

**DRC violations**: Initial TritonRoute pass produced 12 met1 violations (Short + Metal Spacing) near the `Vmem_Array` in conv channel [2]. A second TritonRoute pass on the routed ODB resolved all violations → 0 DRC.

---

## Conv+Pool Core — `SNN_Conv_Top` (Clock-Gating Ablation)

Two full RTL-to-GDSII runs on the Conv+Pool core only (no FC, no SRAM macros), with identical PDK, floorplan, and constraints. The only difference is `ClockGate.sv`: latch-based ICG vs. a wire passthrough (`assign Q = CK`).

| Metric | without ICG | with ICG | Delta |
|--------|-------------|----------|-------|
| Total power (estimated) | 1050 mW | **453 mW** | **−56.8%** |
| — internal (clock-pin) | 622 mW | 182 mW | −70.9% |
| — switching | 429 mW | 272 mW | −36.6% |
| Fmax | 59.3 MHz | **57.5 MHz** | −1.8 MHz |
| Setup WNS @ 50 MHz | +3.14 ns | +2.61 ns | — |
| Hold WNS @ 50 MHz | +0.41 ns | +0.12 ns | — |
| Core area | 8.875 mm² | 8.875 mm² | identical |
| Standard cells | 361,728 | 361,933 | +205 (ICG cells) |
| Sequential cells | 125,346 | 125,349 | identical |
| Routing DRC | 0 | 0 | both clean |

ICG cuts total power 56.8%; internal power (clock-pin toggling) drops 70.9% because idle registers' clock pins stop switching. The 1.8 MHz Fmax cost is the latch insertion delay through the ICG cell.

> Power figures are OpenROAD post-route estimates at default activity factors, not silicon measurement. The comparison is valid because both runs used identical settings.

Full metrics: [`reports/6_report_icg.json`](reports/6_report_icg.json), [`reports/6_report_noicg.json`](reports/6_report_noicg.json).

---

## Setup — Full System P&R

```bash
# Pull Docker image
docker pull openroad/orfs:latest

# Run full flow
docker run --rm -v $(pwd):/work openroad/orfs:latest \
  bash -c 'cd /OpenROAD-flow-scripts/flow && \
    make DESIGN_CONFIG=/work/asic/flow/config.mk'
```

> `SKIP_CTS_REPAIR_TIMING = 1` is set in `config.mk` to work around a
> `detailed_placement` SIGILL on some Zen2 hosts during CTS timing repair.

### Results location

After the flow completes, deliverables are in `asic/flow/orfs_results/`:

| File | Description |
|------|-------------|
| `6_final_fixed.gds` | DRC-clean GDSII (461 MB) |
| `6_final_fixed.def` | Final placement/routing DEF |
| `6_final_fixed.odb` | OpenROAD database |
| `6_final_fixed.v` | Gate-level netlist |
| `6_final.spef` | RC parasitics from OpenRCX |
