#!/usr/bin/env python3
"""
pack_weights_32bit.py  —  Repack 8-bit FC weights into 32-bit words for SRAM loading

Input:  data/weights_fc.hex   (13520 × 8-bit hex values, one per line)
Output: data/weights_fc_32bit.hex   (3380 × 32-bit hex values, one per line)

Packing format (little-endian byte order, matching SKY130 macro convention):
  32-bit word w  =  {byte[4w+3], byte[4w+2], byte[4w+1], byte[4w+0]}
  i.e., word[7:0]   = byte at flat index 4w+0
        word[15:8]  = byte at flat index 4w+1
        word[23:16] = byte at flat index 4w+2
        word[31:24] = byte at flat index 4w+3

Bank-major ordering for FC_SRAM_Loader:
  Words 0   .. 337 : Bank 0  (FC class 0 weights)
  Words 338 .. 675 : Bank 1  (FC class 1 weights)
  ...
  Words 3042..3379 : Bank 9  (FC class 9 weights)

Usage:
  python3 asic/scripts/pack_weights_32bit.py
"""
from pathlib import Path

NUM_BANKS      = 10
DEPTH          = 1352        # bytes per bank
WORDS_PER_BANK = DEPTH // 4  # = 338 (DEPTH is exactly divisible by 4)

src = Path("data/weights_fc.hex")
dst = Path("data/weights_fc_32bit.hex")

# Read 8-bit values (handles both signed two's-complement and unsigned hex)
raw_bytes = []
for line in src.read_text().splitlines():
    line = line.strip()
    if line:
        val = int(line, 16) & 0xFF   # mask to 8-bit (handles signed two's-comp)
        raw_bytes.append(val)

assert len(raw_bytes) == NUM_BANKS * DEPTH, \
    f"Expected {NUM_BANKS * DEPTH} bytes, got {len(raw_bytes)}"

with dst.open("w") as f:
    for bank in range(NUM_BANKS):
        base = bank * DEPTH
        for w in range(WORDS_PER_BANK):
            b = [raw_bytes[base + w * 4 + lane] for lane in range(4)]
            # Little-endian pack: byte 0 in bits [7:0]
            word32 = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
            f.write(f"{word32:08x}\n")

print(f"Packed {NUM_BANKS} banks × {WORDS_PER_BANK} words → {dst}")
print(f"Total: {NUM_BANKS * WORDS_PER_BANK} 32-bit words written")
