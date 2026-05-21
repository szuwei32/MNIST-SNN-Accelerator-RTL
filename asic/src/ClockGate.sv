// =============================================================================
// ClockGate.sv — Integrated Clock Gate (ICG) behavioral model
//
// Latch-based ICG: enable is sampled on the falling edge of CK to prevent
// glitches on the gated clock output Q.
//
// Synthesis mapping:
//   SKY130HD : sky130_fd_sc_hd__dlclkp_1  (CK→CLK, EN→GATE, Q→GCLK)
//   Generic  : replace with target PDK ICG cell via techmap
//              or use Yosys -clkgate pass for automatic ICG inference
//
// Power benefit:
//   When EN=0, Q is held low — downstream flip-flops see no rising edges
//   and consume only leakage current (zero dynamic power).
// =============================================================================
module ClockGate (
    input  logic CK,   // source clock
    input  logic EN,   // clock enable (active high)
    output logic Q     // gated clock — safe, glitch-free output
);
    logic en_latch;

    // Transparent-low latch: captures EN while CK is low, holds during CK high.
    // This ensures EN is stable before the rising edge, preventing glitches.
    always_latch begin
        if (!CK) en_latch <= EN;
    end

    assign Q = CK & en_latch;

endmodule
