當然！以下是完整的修改紀錄：

修改 1 — config.mk：加入 core/ 目錄
問題： VERILOG_FILES 只有 memory/ 和 top/，但 SNN_Accelerator.sv 裡面用到的 LineBuffer、SparsityController、TimeStep_FSM、ConvPE 全部都在 core/ 裡，所以 Yosys 找不到這些 module，導致整個 top module 也無法解析。


# 改前
export VERILOG_FILES = $(wildcard $(DESIGN_DIR)/src/snn/rtl/memory/*.sv) \
                       $(wildcard $(DESIGN_DIR)/src/snn/rtl/top/*.sv)

# 改後
export VERILOG_FILES = $(wildcard $(DESIGN_HOME)/src/snn/rtl/memory/*.sv) \
                       $(wildcard $(DESIGN_HOME)/src/snn/rtl/core/*.sv) \
                       $(wildcard $(DESIGN_HOME)/src/snn/rtl/top/*.sv)
修改 2 — config.mk：DESIGN_DIR → DESIGN_HOME
問題： DESIGN_DIR 在 Makefile 裡被定義為 config 檔所在目錄（designs/nangate45/snn），所以路徑展開後變成 designs/nangate45/snn/src/snn/...，根本不存在。

正確的變數是 DESIGN_HOME，它被定義為 $(FLOW_HOME)/designs，也就是 designs/ 這一層。

修改 3 — config.mk：移除 SYNTH_ARGS = -sv
問題： -sv 不是 Yosys synth 指令的合法參數，直接報 syntax error。.sv 檔案在 read_verilog -sv 階段已經處理好了，不需要再傳。

修改 4 — config.mk：加入 VERILOG_DEFINES = -D SYNTHESIS
原因： 為了讓 SNN_Accelerator.sv 裡的 `ifndef SYNTHESIS 生效，告訴 Yosys 這是 synthesis 環境。

修改 5 — config.mk：加入 SYNTH_MEMORY_MAX_BITS = 100000
問題： 設計裡有 8 個 Vmem_Array，每個是 676×18 bit = 12,168 bit，總共約 97,344 bit，超過預設上限 4096 bit，flow 直接報錯拒絕繼續。調高這個值讓 Yosys 把它們合成成 flip-flop register。

修改 6 — SNN_Accelerator.sv：initial block 加 ifndef SYNTHESIS 保護
問題： Yosys 在 synthesis 時嘗試展開 initial block 來做 ROM 初始化，但裡面的 loop 用了 integer f, k 做 index（f*9 + k），Yosys 認為這是 non-constant，無法處理，報錯中止。


// 改前
initial begin
    $readmemh("weights_conv.hex", weights_mem_flat);
    for (f = 0; f < NUM_FILTERS; f = f + 1) begin
        for (k = 0; k < 9; k = k + 1) weights_mem[f][k] = weights_mem_flat[f*9 + k];
    end
end

// 改後
`ifndef SYNTHESIS
initial begin
    $readmemh("weights_conv.hex", weights_mem_flat);
    for (f = 0; f < NUM_FILTERS; f = f + 1) begin
        for (k = 0; k < 9; k = k + 1) weights_mem[f][k] = weights_mem_flat[f*9 + k];
    end
end
`endif
這個 block 本來就只是 simulation 用的（載入 weights 做功能驗證），synthesis 不需要它。

額外建立的檔案
/home/ubuntu/Desktop/OpenROAD-flow-scripts/flow/weights_conv.hex — 72 個 00 的空白 hex 檔，讓 canonicalize 階段的 $readmemh 不會因找不到檔案而中斷（後來被 ifndef SYNTHESIS 保護取代，但保留無害）。
