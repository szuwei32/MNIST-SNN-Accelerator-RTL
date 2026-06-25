# MNIST SNN Accelerator ASIC P&R Summary

OpenROAD Flow Scripts (ORFS), SKY130HD.

## Design

- Top module: `Top_System_SRAM`
- Architecture: Conv(8 filters) -> AvgPool -> SRAM-backed serial FC(10 classes)
- SRAM macro: 10 x `sky130_sram_1rw1r_64x256_8` (2 KB per bank, 20 KB total)

## Final Physical Implementation

| Metric | Value |
|---|---|
| Die area | 4000 x 4000 um = 16 mm2 |
| Core area | 3980 x 3980 um |
| Placement density | 0.45 |
| Routing layers | signal met1-met4, met5 reserved for PDN |
| Final DRC | 0 violations after TritonRoute repair pass |
| Clean timing point | 25 ns / 40 MHz |
| Post-route WNS @ 40 MHz | +1.033 ns |
| WNS @ 50 MHz | -1.467 ns |

## Key Flow Fixes

- Replaced the original SRAM macro choice with `sky130_sram_1rw1r_64x256_8`, which had usable LEF/LIB/GDS in the local flow.
- Added `fastroute.tcl` with `set_routing_layers -signal met1-met4` to avoid met5 PDN congestion during global routing.
- Added SRAM PDN/global-connection hooks for the OpenRAM macro pins.
- Re-ran TritonRoute on `5_2_route.odb` to repair the remaining 12 met1 DRC violations, producing `5_2_route_fixed.odb` with 0 DRC.

## Timing

Post-route SPEF STA showed:

| Clock period | Frequency | WNS | Status |
|---|---:|---:|---|
| 20 ns | 50 MHz | -1.467 ns | violated |
| 22 ns | 45 MHz | -0.467 ns | violated |
| 25 ns | 40 MHz | +1.033 ns | clean |
| 30 ns | 33 MHz | +3.533 ns | clean |

The limiting 50 MHz path is a clock-gating enable check through the ConvPE/Vmem ICG latch, not the FC accumulator datapath.

## Final Deliverables

Final outputs are generated locally under `asic/flow/orfs_results/` and are not tracked in Git:

| File | Description |
|---|---|
| `6_final_fixed.gds` | DRC-clean routed GDSII |
| `6_final_fixed.def` | Final routed DEF |
| `6_final_fixed.odb` | OpenROAD database |
| `6_final_fixed.v` | Gate-level netlist |
| `6_final.spef` | OpenRCX parasitics |
