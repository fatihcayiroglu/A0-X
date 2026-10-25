# P159 — time-shared bilinear arithmetic over P158/P156 texture BRAM

P158 produced correct bilinear RGBA8 pixels but mapped **24 DSP18 multipliers**
on a real ECP5-85K route: all three four-lane interpolation operations were
combinationally instantiated at once, despite an inherently serialized texture
read frontend. This wastes FPGA multiplier resources needed for more compute
units and fragment lanes.

P159 keeps the P158 public interface and its exact two-stage Q8.8 rounding.
Four P156 BRAM tap reads are unchanged. After the fourth response it runs:

1. `HORIZONTAL0`: calculate and register top-row four-lane RGBA lerp;
2. `HORIZONTAL1`: calculate and register bottom-row lerp with the same DSPs;
3. `VERTICAL`: calculate final four-lane lerp using the same DSPs again.

Input selection is a mux, not three copies of the arithmetic. This trades
**two extra clock cycles per texture lookup** for substantially lower DSP
area. It does not increase sampling throughput (there remains only one
in-flight lookup and one physical P156 read port). Backpressure, tagged
responses, reset safety and initialized-tap presence semantics are unchanged.

## Qualification

Require the original **328-sample independent real-Icarus bilinear oracle**
to pass unchanged, plus real Yosys `synth_ecp5` and nextpnr ECP5-85K full
placement/routing. Assert at least one genuine `DP16KD`, at most **8** (and
at least 1) `MULT18X18D` DSP cells, no unresolved/latch cells, and successful
5 MHz artificial research target timing with unconstrained external pins.
Both checks are fail-closed and upload logs even on failure.

The standalone frequency from FPGA tools is **not** physical board frequency,
and area improvement is **not** a demonstrated gaming FPS improvement. P159
does not add a shader TEX instruction, caches, mipmaps, VRAM, PCIe or drivers.
