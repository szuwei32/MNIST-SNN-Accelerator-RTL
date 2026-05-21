import os
import torch
from torchvision import datasets, transforms

def main():
    transform = transforms.Compose([transforms.ToTensor()])
    test_ds = datasets.MNIST(root="./data", train=False, download=True, transform=transform)

    os.makedirs("data/test_data", exist_ok=True)
    os.makedirs("output", exist_ok=True)

    with open("output/test_labels.txt", "w") as f_labels:
        for i in range(100):
            img, label = test_ds[i]
            pixels = (img.squeeze() * 255).byte().flatten().tolist()
            with open(f"data/test_data/input_image_{i}.hex", "w") as f_img:
                for p in pixels:
                    f_img.write(f"{p:02x}\n")
            f_labels.write(f"{label}\n")

    print("✅ Exported 100 test images to data/test_data/")
    print("✅ Ground-truth labels written to output/test_labels.txt")

if __name__ == "__main__":
    main()
