# P173 — Measured shader/raster throughput, not just FPGA MHz

## Question

P172 proved the full real programmed host + TEX/ALU + raster + P144 framebuffer 
fits at 16×16 on ECP5-85K (77 pins, 5 BRAM, 72 DSP, 37.17 MHz). P173 measures 
**actual hardware clock cycles per 4×4, 8×8 and 16×16 frame draw** and derives 
cycles per pixel for both of the existing P172 shader programs.

## Method

The P172/P102 independent reference test now includes a passive clock-cycle 
monitor. It timestamps the accepted draw command (`draw_fire`) and the actual 
`core_tri_done` pulse. It does **not** count post-draw host framebuffer reads; 
nor does it shortcut shader/texture/depth/BRAM accesses. The two shader programs 
are intentionally different: five instructions and two texture operations 
per shaded fragment versus three instructions and one texture operation. The 
32/128/512 shader results over the corresponding 4/8/16 shapes are checked 
against P102 across 5 full-frame passes per shape. Performance-only output is 
never permitted to replace color/depth and fail-closed tests.

In CI, assert cycle measurements are present, nonvacuous and monotonically 
increase with frame area. Preserve exact logs as artifacts. Calculate measured 
cycles per pixel independently of routed Fmax; approximate theoretical pixel 
rate as `routed_clock_hz / (cycles_per_pixel)`, **not** as a guaranteed game 
FPS or a GPU benchmark. The routed P172 16×16 37.17 MHz is currently the only 
measured frequency for the corresponding 16×16 hardware configuration.

## Boundaries

No hardware silicon, PCB, VRAM controller, PCIe, display connector, external 
driver, raster benchmark at large screen resolution, or modern gaming workload 
is implied. No comparison with RTX 6090 is justified by FPGA clock rate or 
this microbenchmark. Existing 4×4 defaults remain unchanged.
