"""
L1 spike scoreboard.

Compares the RTL layer-1 spike dump (hw_l1_spikes.txt) against:
  1. output/ref_l1_spikes.txt  -- bit-exact integer reference of the same
     fixed-point datapath. A correct RTL must match this 100%.
  2. output/py_l1_spikes.txt   -- float PyTorch golden. The match rate here
     measures how often INT8 quantization + zero-reset LIF agrees with float.

Each line is one packed spike byte for 8 channels at one (image, frame,
spatial) location. Reports per-byte and per-neuron (per-bit) match rates and
the first few diverging locations decoded to (image, frame, row, col).
"""
import os
import sys

OUT_W       = 26
LOCS        = OUT_W * OUT_W       # 676 per frame
FRAMES      = 16
PER_IMAGE   = LOCS * FRAMES       # 10816


def read_bytes(path):
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return [int(l.strip(), 16) for l in fh if l.strip()]


def popcount(x):
    return bin(x).count("1")


def decode(idx):
    img = idx // PER_IMAGE
    within = idx % PER_IMAGE
    frame = within // LOCS
    loc = within % LOCS
    return img, frame, loc // OUT_W, loc % OUT_W


def compare(name, hw, ref):
    print(f"\n=== HW vs {name} ===")
    if ref is None:
        print(f"  [skip] reference file missing")
        return
    if len(hw) != len(ref):
        print(f"  [WARN] length mismatch: HW={len(hw)}  {name}={len(ref)} "
              f"(comparing first {min(len(hw), len(ref))})")
    n = min(len(hw), len(ref))

    byte_mismatch = 0
    bit_mismatch = 0
    examples = []
    for i in range(n):
        if hw[i] != ref[i]:
            byte_mismatch += 1
            bit_mismatch += popcount(hw[i] ^ ref[i])
            if len(examples) < 8:
                img, fr, r, c = decode(i)
                examples.append(
                    f"    img {img:>3} frame {fr:>2} (r{r:>2},c{c:>2}): "
                    f"HW={hw[i]:08b}  {name}={ref[i]:08b}")

    total_neurons = n * 8
    print(f"  spike bytes compared : {n}")
    print(f"  byte-exact matches   : {n - byte_mismatch}/{n} "
          f"({100.0 * (n - byte_mismatch) / n:.4f}%)")
    print(f"  per-neuron matches   : {total_neurons - bit_mismatch}/{total_neurons} "
          f"({100.0 * (total_neurons - bit_mismatch) / total_neurons:.4f}%)")
    if examples:
        print(f"  first diverging locations:")
        print("\n".join(examples))
    else:
        print(f"  >>> BIT-EXACT MATCH on all {total_neurons} neuron-frames <<<")


def main():
    hw = read_bytes("hw_l1_spikes.txt") or read_bytes("output/hw_l1_spikes.txt")
    if hw is None:
        print("[ERROR] hw_l1_spikes.txt not found. "
              "Run: vvp snn_sim +DUMP_L1   (or: make verify-l1)")
        sys.exit(1)

    print(f"HW L1 spike dump: {len(hw)} bytes "
          f"(~{len(hw) / PER_IMAGE:.2f} images @ {PER_IMAGE}/image)")

    compare("INT reference", hw, read_bytes("output/ref_l1_spikes.txt"))
    compare("PyTorch float", hw, read_bytes("output/py_l1_spikes.txt"))


if __name__ == "__main__":
    main()
