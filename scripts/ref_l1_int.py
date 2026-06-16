"""
Bit-exact integer reference for the layer-1 (Conv+LIF) spike output.

This reproduces the *exact* fixed-point datapath in rtl/core/ConvPE.sv from the
same INT8 weights (data/weights_conv.hex) and 8-bit images (data/test_data/)
the RTL consumes — no floats, no PyTorch. It is the golden the RTL is supposed
to implement, so a correct RTL should match it bit-for-bit on every neuron.

Per output neuron (filter f, position r,c), with the same image re-streamed for
every one of T=16 frames so the conv sum S is constant across frames:

    frame 0 :  V = S                 (clear_mem asserted, V_prev = 0)
    frame t :  V = (V_prev >>> 1) + S   (arithmetic shift = LIF beta=0.5 decay)
    spike   =  (V >= V_THRESH)
    on spike:  V <- 0                 (hardware reset-to-zero)

The 8 channel spikes at each spatial location are packed LSB-first into one byte
(bit f = filter f), matching SNN_Accelerator's m_axis_spike bus and the
dump order in sim/tb_Batch_Test.sv (image -> frame -> raster spatial).

Output: output/ref_l1_spikes.txt  (one 2-char hex byte per line)
"""
import os
import numpy as np

NUM_FILTERS = 8
IMG_W       = 28
OUT_W       = 26          # 28 - 3 + 1
NUM_FRAMES  = 16
V_THRESH    = 58144       # must match Top_System.sv u_l1_conv .V_THRESH
NUM_IMAGES  = 100


def load_int8_hex(path, n):
    vals = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            if v >= 128:          # 2's-complement signed int8
                v -= 256
            vals.append(v)
    assert len(vals) == n, f"{path}: expected {n}, got {len(vals)}"
    return vals


def load_u8_hex(path, n):
    vals = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            vals.append(int(line, 16))
    assert len(vals) == n, f"{path}: expected {n}, got {len(vals)}"
    return vals


def main():
    os.makedirs("output", exist_ok=True)

    # weights: [filter][k] in raster order, matching o_window[0..8]
    w = load_int8_hex("data/weights_conv.hex", NUM_FILTERS * 9)
    W = np.array(w, dtype=np.int64).reshape(NUM_FILTERS, 3, 3)

    bit_weight = (1 << np.arange(NUM_FILTERS)).reshape(NUM_FILTERS, 1, 1)

    lines = []
    for img_idx in range(NUM_IMAGES):
        px = load_u8_hex(f"data/test_data/input_image_{img_idx}.hex", IMG_W * IMG_W)
        img = np.array(px, dtype=np.int64).reshape(IMG_W, IMG_W)

        # Constant per-frame conv sum S[f, r, c] (valid 3x3 cross-correlation).
        S = np.zeros((NUM_FILTERS, OUT_W, OUT_W), dtype=np.int64)
        for f in range(NUM_FILTERS):
            acc = np.zeros((OUT_W, OUT_W), dtype=np.int64)
            for i in range(3):
                for j in range(3):
                    acc += img[i:i + OUT_W, j:j + OUT_W] * W[f, i, j]
            S[f] = acc

        V = np.zeros((NUM_FILTERS, OUT_W, OUT_W), dtype=np.int64)
        for t in range(NUM_FRAMES):
            Vc = np.zeros_like(V) if t == 0 else (V >> 1)   # arithmetic shift
            Vn = Vc + S
            spike = Vn >= V_THRESH
            V = np.where(spike, 0, Vn)                       # reset-to-zero

            byte = np.sum(spike.astype(np.int64) * bit_weight, axis=0)  # (26,26)
            for r in range(OUT_W):
                for c in range(OUT_W):
                    lines.append(f"{int(byte[r, c]):02x}")

    with open("output/ref_l1_spikes.txt", "w") as fo:
        fo.write("\n".join(lines) + "\n")
    print(f"[OK] wrote output/ref_l1_spikes.txt ({len(lines)} spike bytes "
          f"= {NUM_IMAGES} imgs x {NUM_FRAMES} frames x {OUT_W*OUT_W} locations)")


if __name__ == "__main__":
    main()
