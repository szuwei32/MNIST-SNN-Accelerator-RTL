"""
Float PyTorch golden for the layer-1 (Conv+LIF) spike output.

Runs the trained HWFriendlySNN (float weights) over the same 100 MNIST test
images the hardware sees, with pixels quantized to the 8-bit range the RTL
consumes, and dumps the layer-1 spike train. This is the "PyTorch golden model"
the design is validated against; scripts/diff_l1.py compares it against the RTL
dump (hw_l1_spikes.txt) to quantify how often INT8 quantization + the
zero-reset hardware LIF flips an L1 firing decision relative to float.

Spikes are packed LSB-first per spatial location (bit c = channel c) and written
in image -> frame -> raster-spatial order, matching the RTL dump.

Output: output/py_l1_spikes.txt  (one 2-char hex byte per line)
"""
import os
import torch
from torchvision import datasets, transforms
from snn import HWFriendlySNN

NUM_FRAMES = 16
NUM_IMAGES = 100
NUM_CH     = 8
OUT_LOCS   = 26 * 26


def main():
    os.makedirs("output", exist_ok=True)

    model = HWFriendlySNN()
    model.load_state_dict(torch.load("data/snn_model.pth", map_location="cpu"))
    model.eval()

    transform = transforms.Compose([transforms.ToTensor()])
    test_ds = datasets.MNIST(root="./data", train=False, download=False,
                             transform=transform)

    bit_weight = (1 << torch.arange(NUM_CH))  # [8]

    lines = []
    with torch.no_grad():
        for img_idx in range(NUM_IMAGES):
            x, _ = test_ds[img_idx]
            x = torch.round(x * 255.0) / 255.0   # match HW 8-bit input quantization
            x = x.unsqueeze(0)                   # [1,1,28,28]

            mem1 = model.lif1.init_leaky()
            for _ in range(NUM_FRAMES):
                cur1 = model.conv1(x)
                spk1, mem1 = model.lif1(cur1, mem1)

                # [8,26,26] -> [676,8] (channel last), matching the HW stream order
                spk = (spk1[0].permute(1, 2, 0).reshape(OUT_LOCS, NUM_CH) > 0)
                byte = (spk.to(torch.int64) * bit_weight).sum(dim=1)  # [676]
                lines.extend(f"{int(v):02x}" for v in byte.tolist())

    with open("output/py_l1_spikes.txt", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"[OK] wrote output/py_l1_spikes.txt ({len(lines)} spike bytes "
          f"= {NUM_IMAGES} imgs x {NUM_FRAMES} frames x {OUT_LOCS} locations)")


if __name__ == "__main__":
    main()
