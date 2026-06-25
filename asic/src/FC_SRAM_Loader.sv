// =============================================================================
// FC_SRAM_Loader.sv  —  Boot-time weight loader for FC SRAM banks
//
// Problem
// ───────
//   SKY130 SRAM macro cells are unpredictable at power-on.  The simulation
//   flow uses $readmemh (simulation-only).  This module streams 64-bit weight
//   words into each of the 10 FCWeightSRAM banks via Port 0 (RW) at boot time.
//
// Architecture
// ────────────
//   1. Source: 64-bit word stream (SPI flash controller, AXI4-Lite bridge, etc.)
//   2. FSM iterates Bank 0 addr 0→168, Bank 1 addr 0→168, … Bank 9 addr 0→168.
//   3. Outputs: per-bank chip-select (bank_csb[k] = 0 for the active bank),
//      shared 64-bit write bus for all FCWeightSRAM Port-0 inputs.
//
// Connection plan (NOT yet wired in Top_System_SRAM):
// ────────────────────────────────────────────────────
//   FC_SRAM_Loader u_loader (
//       .clk(clk), .rst_n(rst_n),
//       .w_valid(w_valid), .w_data(w_data), .w_ready(w_ready),
//       .bank_csb(bank_csb), .ld_web(ld_web), .ld_wmask(ld_wmask),
//       .ld_addr(ld_addr), .ld_din(ld_din), .load_done(load_done)
//   );
//   FCWeightSRAM Port 0 (per bank k):
//     .csb0   = bank_csb[k]
//     .web0   = ld_web
//     .wmask0 = ld_wmask
//     .addr0  = ld_addr
//     .din0   = ld_din
//
//   Inference must be gated on load_done:
//     gated_valid = orig_valid && load_done;
//
// Weight stream ordering (bank-major)
// ────────────────────────────────────
//   Bank 0:  words 0..168  (weights_fc bytes 0..1351)
//   Bank 1:  words 0..168  (weights_fc bytes 1352..2703)
//   …
//   Bank 9:  words 0..168
//   Each 64-bit word packs 8 consecutive bytes (little-endian):
//     word[7:0]=byte[8w], word[15:8]=byte[8w+1], …, word[63:56]=byte[8w+7]
//   See asic/scripts/pack_weights_64bit.py for the packing script.
// =============================================================================
module FC_SRAM_Loader #(
    parameter int NUM_BANKS      = 10,
    parameter int WORDS_PER_BANK = 169   // ceil(1352 / 8) — exact for DEPTH=1352
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Weight word stream (valid/ready handshake, 64 bits per word)
    input  logic                     w_valid,
    input  logic [63:0]              w_data,
    output logic                     w_ready,

    // Write bus to FCWeightSRAM Port 0 (shared except per-bank csb)
    output logic [NUM_BANKS-1:0]     bank_csb,   // 0 = active bank selected
    output logic                     ld_web,     // write-enable bar (0 during writes)
    output logic [7:0]               ld_wmask,   // byte write mask (8 lanes)
    output logic [7:0]               ld_addr,    // 8-bit word address (0..168)
    output logic [63:0]              ld_din,     // write data (registered from stream)

    output logic                     load_done   // asserted when all banks loaded
);

    typedef enum logic [1:0] {
        IDLE    = 2'd0,
        LOADING = 2'd1,
        DONE    = 2'd2
    } state_t;

    state_t             state;
    logic [3:0]         bank_cnt;   // 0 .. NUM_BANKS-1
    logic [7:0]         addr_cnt;   // 0 .. WORDS_PER_BANK-1
    logic [63:0]        din_reg;    // pipeline register for write data

    // Accept one word per cycle when active and source provides valid data
    assign w_ready = (state == LOADING);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            bank_cnt  <= '0;
            addr_cnt  <= '0;
            din_reg   <= '0;
            load_done <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    state    <= LOADING;
                    bank_cnt <= '0;
                    addr_cnt <= '0;
                end

                LOADING: begin
                    if (w_valid) begin
                        din_reg <= w_data;

                        if (addr_cnt == 8'(WORDS_PER_BANK - 1)) begin
                            addr_cnt <= '0;
                            if (bank_cnt == 4'(NUM_BANKS - 1)) begin
                                state     <= DONE;
                                load_done <= 1'b1;
                            end else begin
                                bank_cnt <= bank_cnt + 1;
                            end
                        end else begin
                            addr_cnt <= addr_cnt + 1;
                        end
                    end
                end

                DONE: ; // hold load_done until next reset

                default: state <= IDLE;
            endcase
        end
    end

    // Write control: active only in LOADING state when source provides data
    assign ld_web   = !(state == LOADING && w_valid);   // 0 = write
    assign ld_wmask = 8'hff;                             // all 8 byte lanes
    assign ld_addr  = addr_cnt;
    assign ld_din   = din_reg;   // registered data (one cycle behind w_data)

    // Per-bank chip select: only the current bank is selected during writes
    always_comb begin
        bank_csb = '1;  // all disabled by default
        if (state == LOADING && w_valid)
            bank_csb[bank_cnt] = 1'b0;
    end

endmodule
