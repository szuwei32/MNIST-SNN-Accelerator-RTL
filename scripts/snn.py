import os
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import snntorch as snn
from snntorch import surrogate


class HWFriendlySNN(nn.Module):
    def __init__(self):
        super().__init__()
        
        # 1. Convolutional Layer (Bias=False to save hardware adders/resources)
        self.conv1 = nn.Conv2d(1, 8, kernel_size=3, padding=0, bias=False)
        
        # 2. LIF Neuron 
        # Setting beta=0.5 is key! In hardware, leakage can be implemented as 
        # Vmem - (Vmem >> 1), making it completely multiplier-free.
        # fast_sigmoid is a surrogate gradient used to overcome the non-differentiability 
        # of spikes during training; it is not needed in the actual hardware logic.

        spike_grad = surrogate.fast_sigmoid()
        self.lif1 = snn.Leaky(beta=0.5, spike_grad=spike_grad, threshold=1.0)
        
        # 3. Fully Connected Layer
        self.fc1 = nn.Linear(8 * 13 * 13, 10, bias=False)
        self.lif2 = snn.Leaky(beta=0.5, spike_grad=spike_grad, threshold=1.0)

    def forward(self, x):
        # Initialize membrane potentials (Vmem) for both LIF layers
        mem1 = self.lif1.init_leaky()
        mem2 = self.lif2.init_leaky()
        
        # Record output spikes from the final layer at each time step
        spk2_rec = []
        
        # Set simulation time steps T=16 
        # (The hardware will run 16 clock cycles for the same input image)
        num_steps = 16 
        
        for step in range(num_steps):
           # Convolutional operation
            cur1 = self.conv1(x)
            
            # First LIF layer spike generation
            spk1, mem1 = self.lif1(cur1, mem1)
            
            # Hardware-friendly dimensionality reduction: Average Pooling
            # In hardware, this is equivalent to summing spikes within a 2x2 window 
            # (max value of 4) before passing to the next layer.
            pool1 = F.avg_pool2d(spk1, 2)
            
            # Flatten and pass to the Fully Connected layer
            cur2 = self.fc1(pool1.flatten(1))
            
            # Second LIF layer spike generation
            spk2, mem2 = self.lif2(cur2, mem2)
            
            # Collect prediction results for each time step
            spk2_rec.append(spk2)
            
        # Sum the spikes across 16 time steps. 
        # The neuron with the highest spike count is our predicted class.
        return torch.stack(spk2_rec, dim=0).sum(dim=0)

# ==========================================
# 2. Training and Testing Loop
# ==========================================
def main():
    torch.manual_seed(42)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    
    # Load MNIST Dataset
    transform = transforms.Compose([transforms.ToTensor()])
    train_ds = datasets.MNIST(root="./data", train=True, download=True, transform=transform)
    test_ds  = datasets.MNIST(root="./data", train=False, download=True, transform=transform)
    
    train_loader = DataLoader(train_ds, batch_size=128, shuffle=True)
    test_loader  = DataLoader(test_ds, batch_size=256, shuffle=False)

    model = HWFriendlySNN().to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=2e-3)
    
    # SNN-specific Loss: Apply CrossEntropy directly to the sum of spikes over T time steps
    criterion = nn.CrossEntropyLoss()

    print("=== Starting SNN Model Training ===")
    num_epochs = 3 
    
    for epoch in range(num_epochs):
        model.train()
        total_loss = 0
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            
            optimizer.zero_grad()
            
            # 'out' represents the accumulated spike counts for each class over T=16 steps
            out = model(x) 
            loss = criterion(out, y)
            loss.backward()
            optimizer.step()
            
            total_loss += loss.item()
            
        print(f"Epoch {epoch+1}/{num_epochs} - Loss: {total_loss/len(train_loader):.4f}")

    print("\n=== 開始 SNN 模型測試 ===")
    model.eval()
    correct = 0
    total = 0
    with torch.no_grad():
        for x, y in test_loader:
            x, y = x.to(device), y.to(device)
            out = model(x)
            
           # The predicted class is the index with the most accumulated spikes
            _, predicted = out.max(1)
            total += y.size(0)
            correct += (predicted == y).sum().item()
            
    print(f"Test Accuracy: {100 * correct / total:.2f}%")
    # Save the trained model weights
    os.makedirs("data", exist_ok=True)
    torch.save(model.state_dict(), 'data/snn_model.pth')
    print("✅ Model weights saved to 'data/snn_model.pth'")
if __name__ == "__main__":
    main()