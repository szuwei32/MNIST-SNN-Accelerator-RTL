#!/usr/bin/env python3
"""
pack_weights_64bit.py  —  Repack 8-bit FC weights into 64-bit words for SRAM loading

Input:  data/weights_fc.hex   (13520 × 8-bit hex values, one per line)
Output: data/weights_fc_64bit.hex   (1690 × 64-bit hex values, one per line)

Packing format (little-endian byte order, matching SKY130 macro convention):
  64-bit word w  =  {byte[8w+7], ..., byte[8w+1], byte[8w+0]}
  i.e., word[7:0]   = byte at flat index 8w+0
        word[15:8]  = byte at flat index 8w+1
        ...
        word[63:56] = byte at flat index 8w+7

Bank-major ordering for FC_SRAM_Loader:
  Words 0   .. 168 : Bank 0  (FC class 0 weights, 169 × 64-bit = 1352 bytes)
  Words 169 .. 337 : Bank 1  (FC class 1 weights)
  ...
  Words 1521..1689 : Bank 9  (FC class 9 weights)

Usage:
  python3 asic/scripts/pack_weights_64bit.py
"""
from pathlib import Path

NUM_BANKS      = 10
DEPTH          = 1352        # bytes per bank (169 × 8)
WORDS_PER_BANK = DEPTH // 8  # = 169 (DEPTH exactly divisible by 8)

src = Path("data/weights_fc.hex")
dst = Path("data/weights_fc_64bit.hex")

raw_bytes = []
for line in src.read_text().splitlines():
    line = line.strip()
    if line:
        raw_bytes.append(int(line, 16) & 0xFF)

assert len(raw_bytes) == NUM_BANKS * DEPTH, \
    f"Expected {NUM_BANKS * DEPTH} bytes, got {len(raw_bytes)}"

with dst.open("w") as f:
    for bank in range(NUM_BANKS):
        base = bank * DEPTH
        for w in range(WORDS_PER_BANK):
            b = [raw_bytes[base + w * 8 + lane] for lane in range(8)]
            word64 = sum(b[i] << (i * 8) for i in range(8))
            f.write(f"{word64:016x}\n")

print(f"Packed {NUM_BANKS} banks × {WORDS_PER_BANK} words → {dst}")
print(f"Total: {NUM_BANKS * WORDS_PER_BANK} 64-bit words written")
