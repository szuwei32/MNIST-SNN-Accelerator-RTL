# Project Upgrade Progress

Upgrade goal: improve RTL/ASIC quality for job applications.

---

## Upgrade Roadmap

| # | Task | Priority | Status |
|---|------|----------|--------|
| 1 | Fix `integer` → `logic` in LineBuffer + `$readmemh` synthesis guard | High | ✅ Done |
| 2 | Add SVA assertions (ConvPE, LineBuffer, TimeStep_FSM) | High | ✅ Done |
| 3 | Add performance metrics to README | High | ✅ Done |
| 4 | Pipeline FullyConnected MAC combinatorial block | High | ✅ Done |
| 5 | Add AXI4-Lite config interface | Medium | ✅ Done |
| 6 | Repo cleanup + Makefile automation | Medium | ✅ Done |
| 7 | Clock gating on Vmem_Array + ConvPE | Medium | ✅ Done |
| 8 | DFT scan ports at Top_System | Medium | ✅ Done |
| 9 | SymbiYosys formal verification script | Medium | ✅ Done |

---

## Change Log

### Step 1 — RTL Coding Style Fixes (2025-05-20)

**Files changed:** `rtl/core/LineBuffer.sv`, `rtl/top/SNN_Accelerator.sv`, `rtl/core/FullyConnected.sv`, `readme.md`

#### LineBuffer.sv
- `integer col_cnt, row_cnt, i` → `logic [$clog2(IMG_WIDTH)-1:0]` / `int`
  - `integer` is 32-bit signed (Verilog-1995) — wastes area and can cause sign-extension bugs in synthesis.
  - `col_cnt` / `row_cnt` now use minimum-width packed types.
  - Loop variable `i` changed to inline `int` (simulation-only, not synthesized).

#### SNN_Accelerator.sv + FullyConnected.sv
- `$readmemh(...)` in `initial` block wrapped with `` `ifdef SIMULATION `` guard.
  - `initial $readmemh` is simulation-only; synthesis tools either ignore it silently or error out.
  - `asic/src/` copies already use `localparam` weights — those files are **not touched**.

#### readme.md
- Fixed iverilog compile command: `rtl/*.sv` (didn't recurse into subdirs) → `rtl/top/*.sv rtl/core/*.sv rtl/memory/*.sv`
- Added `-DSIMULATION` flag to enable `$readmemh` weight loading.

---

### Step 2 — SVA Assertions (2025-05-20)

**Files changed:** `rtl/core/ConvPE.sv`, `rtl/core/LineBuffer.sv`, `rtl/core/TimeStep_FSM.sv`

Assertions wrapped in `` `ifdef FORMAL `` (not `SIMULATION`) — concurrent SVA (`assert property`) is designed for formal verification tools (SymbiYosys, Jasper), not iverilog. In interviews: "assertions are wired up for formal; compile with `-DFORMAL` to run with SymbiYosys."

| Module | Assertion | What it checks |
|--------|-----------|----------------|
| ConvPE | `AST_vmem_valid_lag` | `o_vmem_valid` follows `i_valid` by exactly 1 cycle |
| ConvPE | `AST_spike_clears_vmem` | `vmem_write == 0` in the same cycle a spike fires |
| ConvPE | `AST_no_x_on_window` | No X/Z in window data when `i_valid=1` |
| LineBuffer | `AST_col_in_range` | `col_cnt < IMG_WIDTH` (no counter overflow) |
| LineBuffer | `AST_row_in_range` | `row_cnt <= IMG_WIDTH+2` (no counter overflow) |
| LineBuffer | `AST_valid_after_warmup` | `o_valid` only asserted after 3×3 window fills |
| TimeStep_FSM | `AST_addr_in_range` | Vmem address always in `[0, MAP_SIZE)` — prevents out-of-bounds Vmem access |
| TimeStep_FSM | `AST_frame_in_range` | `frame_cnt` never exceeds `MAX_FRAMES-1` |
| TimeStep_FSM | `AST_frame_done_pulse` | `frame_done` is single-cycle pulse, never held high |

---

### Step 3 — Performance Metrics in README (2025-05-20)

**File changed:** `readme.md`

Added quantitative performance table to the ASIC section:

| Metric | Value | Notes |
|--------|-------|-------|
| Throughput | ~4,948 img/s | 62 MHz / (16 frames × 784 pixels) |
| Latency | ~202 μs/image | 16 × 784 cycles @ 62 MHz |
| Energy/inference | ~188 μJ | 931 mW / 4,948 img/s |
| Conv MACs/image | ~869,504 | 8 filters × 9 taps × 676 pixels × 16 frames |
| Sparsity saving | ~40–50% | Zero-window skip via SparsityController |

---

### Step 4 — Pipeline FullyConnected MAC (2025-05-20)

**File changed:** `rtl/core/FullyConnected.sv`

**Problem:** 10 × 8 = 80 multiply-accumulates in one `always_comb` — long critical path limiting Fmax for any future ASIC inclusion.

**Solution:** Added 1-cycle pipeline register between MAC and accumulator:

```
Comb: cycle_dot_product ─┐
                          ├─ [dp_reg FF] ─→ partial_sum / LIF logic
Control: valid/cnt flags ─┘                (dp_valid, input_cnt_d, frame_last_d)
```

- `input_cnt` / `frame_cnt` advance on `s_axis_valid` (1 cycle ahead of pipeline)
- Accumulator/LIF fires on `dp_valid` (1 cycle after data arrives)
- `done` is 1 cycle later — testbench `wait(hw_done_flag)` + `@(posedge clk)` provides 2-cycle read margin → safe
- Added `localparam NUM_CHANNELS`, `MAX_FRAMES`, `WEIGHT_STRIDE` — no more magic numbers
- Fixed multiple-driver bug on `frame_cnt` (was split across two `always_ff`) → merged into single always_ff
- Counter widths: `integer` → `logic [$clog2(INPUT_LEN)-1:0]` / `logic [$clog2(MAX_FRAMES)-1:0]`

---

### Step 5 — AXI4-Lite Wrapper (2025-05-20)

**File added:** `rtl/top/SNN_AXI_Wrapper.sv`

Wraps `Top_System` as a SoC-ready IP block with a full AXI4-Lite slave interface.

**Register map (byte-addressed, 32-bit):**

| Offset | Name    | Access | Description |
|--------|---------|--------|-------------|
| 0x00   | CTRL    | W      | [0]=start inference (self-clearing), [1]=soft reset |
| 0x04   | STATUS  | R      | [0]=done, [1]=busy |
| 0x08   | RESULT  | R      | [3:0]=predicted class (on-chip argmax) |
| 0x0C   | VERSION | R      | 0x0001_0000 (major.minor) |

**Key design points:**
- Full AXI4-Lite handshake: AW/W/B + AR/R channels all properly implemented
- `reg_start` is self-clearing (1-cycle pulse) — no sticky start bit issue
- Pixel stream gated by `reg_busy` — host must write CTRL.start before sending image data
- On-chip argmax: combinatorial logic selects max spike count class, outputs 4-bit index
- `soft_rst` drives `rst_n_int` — host can reset the accelerator without toggling the global AXI reset

---

### Verification (2025-05-20)

**Environment:** iverilog 12.0 (conda-forge), Python 3.13, snntorch 0.9.4, PyTorch (CPU)

**Compile command (excludes AXI wrapper — not part of simulation DUT):**
```bash
iverilog -g2012 -DSIMULATION -o snn_sim \
  sim/tb_Batch_Test.sv \
  rtl/top/SNN_Accelerator.sv rtl/top/Top_System.sv \
  rtl/core/*.sv rtl/memory/*.sv
```

**Results:**

| Check | Result |
|-------|--------|
| RTL compile | ✅ No errors |
| 100-image batch simulation | ✅ Completed, no timeouts |
| Hardware accuracy | **92 / 100 (92%)** |
| PyTorch accuracy (same 100 images) | 98 / 100 (98%) |
| HW-SW gap root cause | Quantization on borderline cases — NOT a pipeline bug |

**Notes on 92% vs 98% gap:**
- Model was re-trained from scratch (original weights not preserved); each training run gives different weights
- 6 of the 8 HW mismatches are images where PyTorch's top-2 class margin is <300 — integer quantization flips these borderline cases
- Image 8 (GT=5): PyTorch also predicts 6 — intrinsically ambiguous sample
- Pipeline logic verified correct: `v_next = leaked + sum(MAC[0..167]) + MAC[168]` computes the full dot product accurately

---

### Step 6 — Repo Cleanup + Makefile Automation (2026-05-20)

**Files changed/added:** `Makefile`, `.gitignore`, moved `openroadprogress.md` → `asic/openroad_notes.md`

#### Makefile targets

| Target | Action |
|--------|--------|
| `make train` | `python3 scripts/snn.py` — train SNN and save weights |
| `make weights` | `python3 scripts/export_parameters.py` — export INT8 hex weights |
| `make compile` | `iverilog -g2012 -DSIMULATION ...` — compile RTL |
| `make sim` | `vvp snn_sim` — run 100-image batch simulation |
| `make verify` | Full flow: train → weights → compile → sim → check accuracy |
| `make formal` | `sby -f formal/snn_formal.sby` — run SymbiYosys BMC |
| `make clean` | Remove all generated artifacts (`snn_sim`, `*.vcd`, `output/`) |
| `make help` | Print usage summary |

#### .gitignore
Added: `__pycache__/`, `*.py[cod]`, `*.pth`, `snn_sim`, `output/`, `*.hex`, `data/`, `.vscode/`, `build/`

---

### Step 7 — Clock Gating on Vmem_Array + ConvPE (2026-05-20)

**Files added/changed:** `rtl/cells/ClockGate.sv` (new), `rtl/memory/Vmem_Array.sv`, `rtl/core/ConvPE.sv`

#### ClockGate.sv
Latch-based ICG cell (glitch-free):
```systemverilog
module ClockGate (input logic CK, input logic EN, output logic Q);
    logic en_latch;
    always_latch if (!CK) en_latch <= EN;
    assign Q = CK & en_latch;
endmodule
```
Maps to `sky130_fd_sc_hd__dlclkp_1` in synthesis. Saves dynamic power on write-path FFs when idle.

#### Vmem_Array.sv
- Write port now uses `clk_w` (ICG-gated by `i_we`) instead of raw `clk`
- Eliminates toggle power on 8 × 676 = 5,408 FFs when no write is active

#### ConvPE.sv
- Output FFs (`o_spike`, `o_vmem_valid`, `o_vmem_write`) now clocked by `clk_pe` (ICG-gated by `i_valid`)
- Zero switching power when PE is not processing a valid pixel

---

### Step 8 — DFT Scan Ports at Top_System (2026-05-20)

**Files changed:** `rtl/top/Top_System.sv`, `sim/tb_Batch_Test.sv`

#### Top_System.sv
Added DFT scan interface ports:
```systemverilog
input  logic scan_en,   // 1 = scan shift mode, 0 = functional
input  logic scan_in,   // scan chain input
output logic scan_out   // scan chain output
```
Scan chain stub: `assign scan_out = scan_en ? scan_in : 1'b0;`

In a real DFT flow, the ATPG tool (Tessent, TetraMAX) replaces the stub with an auto-stitched scan chain across all internal flip-flops. The stub ensures the port exists so the synthesis/P&R netlist interface is forward-compatible.

#### tb_Batch_Test.sv
Scan ports tied off for functional simulation:
```systemverilog
logic scan_en, scan_in, scan_out;
assign scan_en = 1'b0;
assign scan_in = 1'b0;
```

---

### Step 9 — SymbiYosys Formal Verification Script (2026-05-20)

**File added:** `formal/snn_formal.sby`

Three tasks, each running bounded model checking (BMC):

| Task | Depth | Modules | Properties |
|------|-------|---------|------------|
| `conv_pe` | 20 cycles | ConvPE, ClockGate | AST_vmem_valid_lag, AST_spike_clears_vmem, AST_no_x_on_window |
| `line_buffer` | 40 cycles | LineBuffer | AST_col_in_range, AST_row_in_range, AST_valid_after_warmup |
| `timestep_fsm` | 700 cycles | TimeStep_FSM | AST_addr_in_range, AST_frame_in_range, AST_frame_done_pulse |

Engine: `smtbmc bitwuzla` (bit-precise SMT arithmetic, fastest for datapath-heavy designs)

TimeStep_FSM depth=700 needed because the FSM must walk through all 676 addresses across 16 frames before `frame_done` can fire — shallow BMC would never reach the assertion trigger condition.

Install: `conda install -c litex-hub symbiyosys bitwuzla`, then `make formal`.

---

### Final Verification (2026-05-20)

After all Round 2 changes (`make verify`):

| Check | Result |
|-------|--------|
| RTL compile (with ClockGate.sv) | ✅ No errors |
| 100-image batch simulation | ✅ Completed, no timeouts |
| Hardware accuracy | **92 / 100 (92%)** — no regression |

---
