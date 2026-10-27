# P193: actual 256×256 ECP5 placement-and-route gate

## Proven inputs
P191 #68: real host graphics operation at 256×4 and 4×256, with a 256×4 physical route at 39.14 MHz. On its exact head, all 16 inherited/new CI workflows completed successfully.

P192 #69: real Icarus host-level 256×256 simulation proved 65,536 sequential clear writes, global high/high and far-corner RGB/depth readback, out-of-range host denial, shader/local UV, nonaliasing, reset denial and full re-clear. The actual LFE5U-85F-targeted Yosys mapping yielded **193 DP16KD / 72 DSP / 15,213 LUT4 / 5,105 FF / 77 IO** with no unmapped cells. Both exact-head P192 workflows succeeded. Resource packing alone does not prove that the design can be placed, routed or clocked.

## P193 objective
Run actual `nextpnr-ecp5` for a **full 256×256** P175 programmable renderer with `TILED_SCREEN_UV=1`, on the 85K CABGA756 speed-6 device, seed 1. Preserve the true timing report, JSON netlist and routed config on pass or failure. A 5 MHz placer request is only a routing-enabling setting: this job **fails** unless the independent JSON post-check proves **at least 30 MHz actual achieved Fmax**. It also enforces 77 pins and mapped BRAM/DSP/LUT/FF bounds.

No physical route or Fmax is established until this job passes on the exact P193 head. Even a passing FPGA research route is not evidence of a PCIe graphics card, user-space drivers, production VRAM system, power integrity, thermals, shader throughput comparable to commercial GPUs, or game FPS.

## Decision rules
- Keep the original red logs and artifact intact. A no-route, timing failure, or capacity overflow is a real result; never label it green or skip it.
- If the route fails, inspect timing paths, BRAM placement, carry/fanout, and FF utilization before making a narrow architectural fix. Do not suppress assertions or lower the 30 MHz threshold to hide a failure.
- Keep this PR draft stacked on P192 #69 and P191 #68; all parents require independent review, exact-head regression checks and safe integration before any merge.
