"""
Bit-exact integer reference for the WHOLE accelerator (end-to-end).

Reproduces the exact fixed-point datapath of the full pipeline from the same
INT8 weights and 8-bit images the RTL consumes — no floats, no PyTorch:

    Conv + LIF (L1)  ->  2x2 sum-pool  ->  FC + LIF  ->  per-class spike count

and emits the 10 final class scores per image, matching Top_System's
`final_scores` bus dumped by sim/tb_Batch_Test.sv (hw_scores.txt).

A correct RTL must match this 100% on every score, which is a full-datapath
sign-off (independent of the 92% end-to-end accuracy vs ground-truth labels).

Datapath details mirrored from rtl/:
  L1  (ConvPE.sv):     V = (V>>1) + conv_sum ; spike if V>=58144 ; reset->0
  Pool(AvgPooling.sv): out = sum of the 2x2 spike block (0..4), per frame
  FC  (FullyConnected.sv, Top_System FC_V_THRESH=643):
       dot[k] = sum_{spatial,ch} pool * w ; v=(v>>1)+dot ;
       spike if v>=643 (reset->0) ; score[k] = spikes over 16 frames
  FC weight layout: w[k*1352 + (R*13+C)*8 + c]  (class, raster-spatial, channel)

Output: output/ref_scores.txt  (10 decimal scores per image, class 0..9)
"""
import os
import numpy as np

NUM_FILTERS = 8
IMG_W       = 28
OUT_W       = 26
POOL_W      = 13
NUM_FRAMES  = 16
NUM_CLASSES = 10
INPUT_LEN   = POOL_W * POOL_W      # 169
L1_V_THRESH = 58144                # Top_System u_l1_conv .V_THRESH
FC_V_THRESH = 643                  # Top_System u_fc .FC_V_THRESH
NUM_IMAGES  = 100


def load_int8_hex(path, n):
    vals = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            if v >= 128:
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

    Wc = np.array(load_int8_hex("data/weights_conv.hex", NUM_FILTERS * 9),
                  dtype=np.int64).reshape(NUM_FILTERS, 3, 3)
    # FC weights: flat k*1352 + (R*13+C)*8 + c  ->  [class, spatial(169), channel(8)]
    Wf = np.array(load_int8_hex("data/weights_fc.hex",
                                NUM_CLASSES * INPUT_LEN * NUM_FILTERS),
                  dtype=np.int64).reshape(NUM_CLASSES, INPUT_LEN, NUM_FILTERS)

    lines = []
    for img_idx in range(NUM_IMAGES):
        px = load_u8_hex(f"data/test_data/input_image_{img_idx}.hex", IMG_W * IMG_W)
        img = np.array(px, dtype=np.int64).reshape(IMG_W, IMG_W)

        # L1 conv sums (constant across frames; same image re-streamed)
        S = np.zeros((NUM_FILTERS, OUT_W, OUT_W), dtype=np.int64)
        for f in range(NUM_FILTERS):
            for i in range(3):
                for j in range(3):
                    S[f] += img[i:i + OUT_W, j:j + OUT_W] * Wc[f, i, j]

        V_l1  = np.zeros((NUM_FILTERS, OUT_W, OUT_W), dtype=np.int64)
        v_fc  = np.zeros(NUM_CLASSES, dtype=np.int64)
        count = np.zeros(NUM_CLASSES, dtype=np.int64)

        for t in range(NUM_FRAMES):
            # --- L1 Conv + LIF ---
            Vc = np.zeros_like(V_l1) if t == 0 else (V_l1 >> 1)
            Vn = Vc + S
            spk = Vn >= L1_V_THRESH                 # (8,26,26) bool
            V_l1 = np.where(spk, 0, Vn)
            sp = spk.astype(np.int64)

            # --- 2x2 sum-pool -> (8,13,13), values 0..4 ---
            pool = (sp[:, 0::2, 0::2] + sp[:, 0::2, 1::2] +
                    sp[:, 1::2, 0::2] + sp[:, 1::2, 1::2])
            pool_flat = pool.transpose(1, 2, 0).reshape(INPUT_LEN, NUM_FILTERS)  # [spatial, ch]

            # --- FC dot product per class ---
            dot = np.einsum('sc,ksc->k', pool_flat, Wf)   # (10,)

            # --- FC LIF over frames ---
            v_next = (v_fc >> 1) + dot
            fire = v_next >= FC_V_THRESH
            count += fire.astype(np.int64)
            v_fc = np.where(fire, 0, v_next)

        lines.extend(str(int(c)) for c in count)

    with open("output/ref_scores.txt", "w") as fo:
        fo.write("\n".join(lines) + "\n")
    print(f"[OK] wrote output/ref_scores.txt "
          f"({len(lines)} scores = {NUM_IMAGES} imgs x {NUM_CLASSES} classes)")


if __name__ == "__main__":
    main()
