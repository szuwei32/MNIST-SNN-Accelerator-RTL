import torch
import os
from snn import HWFriendlySNN 

def int8_to_hex(v):
    # Convert signed int8 to 2-character hex string
    return f"{(int(v) + 256) % 256:02x}"

def export_to_hex(tensor, filename):
    flat_data = tensor.flatten().tolist()
    with open(filename, 'w') as f:
        for val in flat_data:
            f.write(f"{int8_to_hex(val)}\n")

def main():
    device = torch.device("cpu")
    model = HWFriendlySNN().to(device)
    # Load your pre-trained model state
    model.load_state_dict(torch.load('data/snn_model.pth'))
    
    with torch.no_grad():
        # --- Conv1 Quantization ---
        c1_w = model.conv1.weight.data
        c1_scale = 127.0 / c1_w.abs().max()
        c1_quant = torch.round(c1_w * c1_scale).clamp(-128, 127)
        
        fc_w = model.fc1.weight.data
  
        # Reshape [Class, Channel, H, W] to match hardware format [Class, H, W, Channel]
        # Hardware logic processes spatial locations first, then channels.
        fc_w_reshaped = fc_w.view(10, 8, 13, 13).permute(0, 2, 3, 1).reshape(10, -1)
        
        fc_scale = 127.0 / fc_w_reshaped.abs().max()
        fc_quant = torch.round(fc_w_reshaped * fc_scale).clamp(-128, 127)

        vth_conv = 1.0 * c1_scale
        vth_fc = 1.0 * fc_scale * 4.0
        
        
        # Factor in 255.0 to align with the hardware's 8-bit input pixel range
        vth_conv = 1.0 * c1_scale * 255.0
        vth_fc = 1.0 * fc_scale * 4.0

        print("\n========================================================")
        print(f"★ Please ensure ConvPE V_THRESH is set to: {int(vth_conv)}")
        print(f"★ Please ensure FullyConnected FC_V_THRESH is set to: {int(vth_fc)}")
        print("========================================================\n")

    # Export to .hex files for FPGA/Verilog $readmemh
    os.makedirs("data", exist_ok=True)
    export_to_hex(c1_quant, "data/weights_conv.hex")
    export_to_hex(fc_quant, "data/weights_fc.hex")
    print("✅ Spatially aligned weights exported to data/")

if __name__ == "__main__":
    main()