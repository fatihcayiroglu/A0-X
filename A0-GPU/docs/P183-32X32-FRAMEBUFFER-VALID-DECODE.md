# P183: 32×32 validity-decoder timing recovery experiment

## Evidence motivating this bounded change

At P182 head `6e442a24b122972a02309ada703bdc2c92592994`, a constant-index per-valid-bit decoder for **all** framebuffer bank sizes routed on the real CABGA756 ECP5-85F FPGA at **39.26 MHz for 32×32** (77 IO, 5 DP16KD BRAM, 72 MULT18X18D DSP) and **38.56 MHz for 16×16**. Both physical jobs passed. However, that exact revision **failed** P178/P180 large independent full-frame host oracle jobs by exceeding 240 seconds at 128×64, so it could not be accepted.

P182 later constrained that decoder to **BANK_DEPTH <=256**, retaining 16×16 physical **38.56 MHz** and large oracle passing performance but returning 32×32 to the old variable-index validity path at **32.17 MHz**. The historical P177 32×32 result before P180 changes was **35.04 MHz**.

## Single RTL hypothesis

Relax only the generate-time threshold to **BANK_DEPTH <=512**. This includes 32×32 (512 entries per bank) but leaves 32×64 (1024), 64×64 (2048), 128×64 (4096), 128×128 (8192) on the original dynamic-index validity write path; synthesis and simulation use identical elaborated code for each frame shape. No changes to pixel BRAM, arbitration, validity reset, depth, colors, shader arithmetic, control/error timing, or software expectations.

## Required acceptance (no hidden skips)

1. The independent P172 8×8 through 32×32 host-frame oracles and all existing framebuffer correctness tests must pass.
2. P178/P180 real independent large full-frame 128×128/128×64 oracles must pass within their original timeout; no timeout increase or test weakening.
3. Same-seed real ECP5 16×16 route must remain **≥36.5 MHz** (the original fixed physical gate).
4. Same-seed real ECP5 32×32 route must genuinely improve over the corrected P182 **32.17 MHz** and ideally exceed the pre-P180 **35.04 MHz** baseline, without relying on the 5 MHz CI routability floor as a performance claim.
5. Updated main/P179 32×64 physical 77-IO/BRAM/DSP route must pass without a new meaningful regression. No 64×64 physical fit is claimed without actual route.
6. Keep this PR draft while the exact head is unverified; preserve failed evidence. Only integrate into the P180 candidate after all proof, then rerun combined exact-head CI before production main.

FPGA routed MHz are internal research timing results and are **not** GPU frames per second, memory bandwidth or consumer graphics card performance.
