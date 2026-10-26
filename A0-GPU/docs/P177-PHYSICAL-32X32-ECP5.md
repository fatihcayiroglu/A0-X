# P177: real 32×32 ECP5 physical route and resource accounting

## Scope

P176 proved exactly 5,120 host-observed pixels and 2,048 shaded fragments on 32×32 in RTL simulation, with exact program draw times of 52,226 and 34,818 core cycles. Simulation is not proof that the same design fits an FPGA. P177 independently elaborates the **unchanged** P175 isolated scaled core at `FRAME_WIDTH=32`, `FRAME_HEIGHT=32` and executes actual Yosys synthesis plus seeded nextpnr ECP5 place-and-route.

## Strict experimental acceptance

- Fit the full 77-pin programmable host top on an ECP5-85K CABGA756, speed grade 6, seed 1.
- Assert exactly **77 mapped external IO bits**, mapped DSP cells between **40 and 72**, and a bounded **5–16 physical DP16KD BRAMs**. Detect latches and unmapped internal modules.
- Require complete successful place-and-route with a measured `fmax` at or above the **5 MHz research routing target**, recorded from the actual nextpnr timing report.
- Publish full Yosys netlist, Yosys log, route config, nextpnr report and log as a success/failure evidence artifact. Nonzero exits block the PR; missing evidence is not a pass.
- Do not change or weaken the already-proven P171 4×4 ≥40MHz and P172 16×16 ≥36.5MHz gates.

## Interpretation

The 5MHz gate is deliberately the **minimum demonstrable routability threshold**, not a market-ready speed goal. Report actual achieved MHz without presenting a 32×32 result as 1080p/4K throughput, VRAM bandwidth, real game FPS or RTX-class equivalence. Converting the separately measured 32×32 core cycles into an idealized pixel throughput still omits data-transfer and display overhead; label such estimates accordingly.

A failed fit or a BRAM/DSP over-budget result is an engineering finding and remains red until explained and fixed; do not classify it as successful.
