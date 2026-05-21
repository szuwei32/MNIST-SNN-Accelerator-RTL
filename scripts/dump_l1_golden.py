import torch
from torchvision import datasets, transforms
from snn import HWFriendlySNN

def main():
    model = HWFriendlySNN()
    # Load your pre-trained model weights
    model.load_state_dict(torch.load('data/snn_model.pth', map_location='cpu'))
    model.eval()

    # Load the first image (Image 0) from the test dataset
    transform = transforms.Compose([transforms.ToTensor()])
    test_ds = datasets.MNIST(root="./data", train=False, download=False, transform=transform)
    x, y = test_ds[0] 
    x = x.unsqueeze(0) # Expand batch dimension to [1, 1, 28, 28]

    mem1 = model.lif1.init_leaky()
    
    print(f"=== Starting L1 Spike extraction for Image 0 (Ground Truth: {y}) ===")
    
    with open("py_l1_spikes.txt", "w") as f:
        # Run simulation for 16 time steps (frames)
        for step in range(16):
            cur1 = model.conv1(x)
            spk1, mem1 = model.lif1(cur1, mem1)
            
            # spk1 dimensions: [Batch, Channel, Height, Width] -> [1, 8, 26, 26]
            # Since the hardware outputs all 8 channels for a single spatial location per cycle,
            # we need to permute the dimensions to match the hardware streaming format.

            spk_hw_format = spk1[0].permute(1, 2, 0) # Change to [26, 26, 8]
            spk_flat = spk_hw_format.reshape(-1, 8)  # Flatten to [676, 8]
            
            # Convert to 8-bit binary strings for bit-accurate hardware comparison
            for spatial_idx in range(676):
                val = 0
                for c in range(8):
                    if spk_flat[spatial_idx, c].item() > 0:
                        val |= (1 << c)
                f.write(f"{val:08b}\n")

    print("✅ Python L1 Spikes successfully exported to py_l1_spikes.txt")

if __name__ == "__main__":
    main()