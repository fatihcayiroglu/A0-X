# P189: 128x128 actual ECP5 frame-memory scaling experiment (draft)

## Established exact-head baseline
P188 #65 head `62bba48f551dfa651c259822d1859668e54dfc8f` passed a real 64x128 ECP5 route at **40.90 MHz** (77 IO, 25 DP16KD, 72 MULT18X18D, 12,142 LUT4, 5,100 TRELLIS_FF), run 40583873937, artifact 12770379855. Its Icarus full-clear read-mask test also passed. P187 #64 32x64 ECP5 reached 41.79 MHz. These are routed FPGA fabric clocks, not game FPS.

## Isolation
No synthesizable RTL edits. Attempt the same P175 host at **128x128=16,384 pixels** with actual Yosys `synth_ecp5` and nextpnr-ecp5 for LFE5U-85F CABGA756 speed-6, seed 1, default placer, unchanged 77-pin bus. The >=2048 opt-in full-clear guard is unchanged; standalone/default per-pixel validity remains available.

## Falsifiable gates
1. New real Icarus full-clear guard test at the 14-bit index boundary (0..16383): both bank parities, high-half 8192, last pixel 16383, pre-init zero, post-init data visibility, invalidation and reset masks.
2. Real physical place AND route, with raw mapped and routed artifacts retained on failure: 77 IO, 26..96 BRAM, 40..72 DSP, fewer than 9,195 FF, nonzero LUT4 within ECP5 capacity, all routed clock domains at **>=30 MHz** experimental floor. No substitute synthesis-only pass, increased retry or waiver.
3. Preserve all parent large-frame independent 128x128 P180 color/depth/frame/cycle oracles, 16x16/32x32/32x64/64x64/64x128 FPGA regressions, and P186/P187/P188 memory guard tests on exact candidate head prior to integration. Missing runs are not green.
4. Keep **draft**, stacked on #65, and do not merge while parent #57/#63/#64/#65 or independent review is unresolved. This does not imply a commercially usable GPU, PCIe, physical VRAM, drivers or FPS.
