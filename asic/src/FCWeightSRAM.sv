// =============================================================================
// FCWeightSRAM.sv  —  Single-port synchronous FC weight SRAM, one per class
//
// Interface
// ─────────
//   csb        chip-select bar (active-low).
//   addr       flat byte address into this bank  (ADDR_WIDTH bits).
//   rdata      registered byte output; valid one cycle after (addr, csb=0).
//
// Timing model (macro-accurate)
// ──────────────────────────────
//   Cycle T   : present addr, assert csb = 0.
//   posedge T : macro clocks the 64-bit word at addr[ADDR_WIDTH-1:3]  AND
//               registers addr[2:0] as byte_sel_reg.
//   Cycle T+1 : rdata = rdata64[byte_sel_reg × 8  +:  8]  (combinational mux).
//
//   Replicates the pipeline of sky130_sram_1rw1r_64x256_8:
//     • 64-bit registered data output (dout1[63:0]).
//     • Byte-lane selected combinationally from the registered 64-bit word.
//
// Macro choice
// ─────────────
//   sky130_sram_1rw1r_64x256_8 (from OpenRAM / ORFS sky130ram platform):
//     - 64-bit × 256 words = 2 KB capacity per bank  (same as 32×512)
//     - Same port names (clk0/csb0/web0/wmask0/addr0/din0/dout0 + clk1/csb1/addr1/dout1)
//     - LEF/LIB/GDS available in openroad/orfs Docker image
//     - Files stored locally at asic/pdk/sky130_sram_macros/sky130_sram_1rw1r_64x256_8/
//
// Simulation model (SIMULATION guard)
// ────────────────────────────────────
//   Internal 64-bit array:  mem64[0 : DEPTH64-1]
//   Weight packing  (little-endian byte order):
//     mem64[w][b×8 +: 8] = weight at flat byte index  w×8 + b
//   Each instance reads the flat hex file once and copies only its own slice
//   [BANK_ID×DEPTH .. (BANK_ID+1)×DEPTH - 1].
//
//   DEPTH = 1352 bytes (169 positions × 8 channels).
//   DEPTH64 = 169 words (exactly 64-bit aligned: 169×8 = 1352).
//   Word address  addr[ADDR_WIDTH-1:3] = addr[10:3]  (8 bits → 256-word space).
//   Byte select   addr[2:0]             registered alongside the word.
//
// Synthesis path
// ──────────────
//   Port 1 (R-only) → FC_Serial inference reads.
//   Port 0 (RW)     → FC_SRAM_Loader (boot-time weight load); tied off until wired.
// =============================================================================
module FCWeightSRAM #(
    parameter int DEPTH      = 1352,   // byte entries per bank = 169 × 8
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 11,     // covers 0..1351; bits [10:3] = word address
    parameter int BANK_ID    = 0,      // 0 .. NUM_BANKS-1
    parameter int NUM_BANKS  = 10
) (
    input  logic                   clk,
    input  logic                   csb,
    input  logic [ADDR_WIDTH-1:0]  addr,
    output logic [DATA_WIDTH-1:0]  rdata
);

`ifdef SIMULATION
    // -------------------------------------------------------------------------
    // 64-bit internal model  — mirrors sky130_sram_1rw1r_64x256_8
    // -------------------------------------------------------------------------
    localparam int DEPTH64 = (DEPTH + 7) / 8;   // = 169 for DEPTH = 1352

    logic [63:0] mem64        [0:DEPTH64-1];

    // Registered macro outputs — both latched on the same posedge
    logic [63:0] rdata64;       // registered 64-bit word
    logic [2:0]  byte_sel_reg;  // registered byte-lane select from addr[2:0]

    // Per-instance weight loading: read full flat file, pack own slice
    logic signed [DATA_WIDTH-1:0] _flat [0:NUM_BANKS*DEPTH-1];

    initial begin
        $readmemh("data/weights_fc.hex", _flat);

        // Pack 8 consecutive bytes per 64-bit word (little-endian byte order)
        for (int w = 0; w < DEPTH64; w++) begin
            mem64[w] = 64'b0;
            for (int b = 0; b < 8; b++) begin
                if (w * 8 + b < DEPTH)
                    mem64[w][b*8 +: 8] = _flat[BANK_ID * DEPTH + w * 8 + b];
            end
        end

        // Initialize output registers so sub_cnt=1 sees 0 not X before first read
        rdata64      = 64'b0;
        byte_sel_reg = 3'b0;
    end

    // Synchronous read: register the 64-bit word AND the byte-lane simultaneously
    always_ff @(posedge clk) begin
        if (!csb) begin
            rdata64      <= mem64[addr[ADDR_WIDTH-1:3]];  // 8-bit word address
            byte_sel_reg <= addr[2:0];                     // byte lane (0..7)
        end
        // When csb=1, both registers hold their last valid values (macro behaviour)
    end

    // Combinational byte-lane extraction — matches the macro's output mux
    assign rdata = rdata64[byte_sel_reg*8 +: 8];

`else
    // -------------------------------------------------------------------------
    // Synthesis: sky130_sram_1rw1r_64x256_8
    //
    // Port assignment:
    //   Port 1 (R-only) — FC_Serial inference reads.
    //     csb1 ← csb,  addr1 ← addr[10:3] (8-bit word addr),  dout1 → byte mux.
    //
    //   Port 0 (RW)    — boot-time weight loader (not yet connected).
    //     csb0 tied HIGH (disabled).  When FC_SRAM_Loader is integrated:
    //       csb0  ← loader_csb[BANK_ID]
    //       web0  ← 1'b0          (write)
    //       wmask0← 8'hff         (all 8 byte lanes)
    //       addr0 ← loader_word_addr[7:0]
    //       din0  ← loader_word_data[63:0]
    //     See asic/src/FC_SRAM_Loader.sv for the loader FSM.
    //
    // Weight packing for silicon bring-up:
    //   Run  asic/scripts/pack_weights_64bit.py  to produce 64-bit-packed hex;
    //   program into flash and replay via SPI → FC_SRAM_Loader.
    // -------------------------------------------------------------------------
    logic [63:0] dout_rd;      // Port 1 registered output
    logic [2:0]  byte_sel_reg; // byte-lane registered with the Port 1 address

    sky130_sram_1rw1r_64x256_8 u_macro (
        // Port 0 (RW) — weight loader.  Tied off until loader is connected.
        .clk0   (clk),
        .csb0   (1'b1),             // disabled
        .web0   (1'b0),
        .wmask0 (8'h00),
        .addr0  (8'b0),
        .din0   (64'b0),
        .dout0  (),

        // Port 1 (R) — FC_Serial inference reads
        .clk1   (clk),
        .csb1   (csb),
        .addr1  (addr[ADDR_WIDTH-1:3]),  // [10:3] → 8-bit word address (256 words)
        .dout1  (dout_rd)
    );

    // Register byte-lane alongside the Port 1 address (same posedge, same path
    // as the macro's output pipeline — both flip on posedge clk when csb=0).
    always_ff @(posedge clk)
        if (!csb) byte_sel_reg <= addr[2:0];

    // Combinational byte-lane extraction from the registered 64-bit word
    assign rdata = dout_rd[byte_sel_reg * 8 +: 8];

`endif
endmodule
