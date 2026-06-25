# Placement blockage covering the 2-column × 5-row SRAM region
# Prevents standard cells from being placed inside or immediately adjacent to SRAMs.
# Region: x = 0..2107 µm, y = 0..2056 µm (with 10 µm halo around SRAM block)
create_placement_blockage -type hard -bbox {0 0 2107 2056}
