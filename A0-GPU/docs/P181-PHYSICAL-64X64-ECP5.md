# P181: real ECP5 64×64 programmable shader/framebuffer physical route

This isolated experiment is stacked on P180's corrected RTL (`1885004`) to avoid obsolete signed-Q8.8 UV behavior. P178 independently checked 64×64 full frames in real RTL **simulation**, which cannot prove a physically routed FPGA. P179 physically routed 32×64 at 29.01 MHz (77 IO, 7 DP16KD, 72 DSP). P180's corrected 32×32 RTL physically routed at 31.28 MHz (versus older 35.04 MHz). Neither implies 64×64 fits.

## Strict exact-head acceptance contract

- Run real Yosys `synth_ecp5` and `check -assert` on `a0_p175_scaled_programmed_command_top` with `FRAME_WIDTH=64`, `FRAME_HEIGHT=64`.
- Run actual nextpnr-ecp5 place-and-route for LFE5U-85F CABGA756, speed 6, seed 1, with minimum **5 MHz exploratory routing** floor, not a GPU performance target.
- Require exactly 77 host pins, 7..32 DP16KD memory blocks, 40..72 MULT18X18D DSP blocks, nonzero Yosys LUT4 and TRELLIS_FF counts within 83,640 device ceiling, and no unresolved cells or latches. Never demand a `TRELLIS_COMB` key in the Yosys netlist: nextpnr's placed-device report uses that name, whereas the netlist uses `LUT4` (original P179 guard bug).
- Require actual successful physical routing and positive `route.json` `fmax.achieved` at least 5 MHz before printing a PASS marker. Preserve the entire netlist, synth log, route timing/area report and nextpnr log **even on failures**. A failed or incomplete route blocks merging.
- Keep all earlier P172/P173/P177/P178/P179/P180 gates intact; no skips, no simulation-substituted route claim.

## Analysis and next step

If route succeeds, record measured 64×64 MHz, RAM, DSP, Yosys LUT4, FF and nextpnr TRELLIS_COMB for controlled comparison. Inspect the framebuffer validity-bit write path: P180 32×32 changed the physical critical path from 8.6 ns logic + 20.0 ns routing to 9.3 ns logic + 22.7 ns routing. These values do not identify a unique source-code root cause. If the 64×64 place/route fails, preserve its evidence and consider staged/pipelined validity addressing on a separate branch, guarded by independent framebuffer color/depth/fault oracles.

**Nonclaims:** A routed 64×64 FPGA is not a display output, memory bandwidth result, GPU fill rate, PC gaming FPS, drivers, PCIe hardware, production ASIC or RTX 6090 competitiveness. P180 #57 must complete and integrate safely before this stacked P181 PR can target production main.
