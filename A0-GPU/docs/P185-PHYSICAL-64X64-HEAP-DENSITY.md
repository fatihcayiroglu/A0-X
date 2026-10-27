# P185: 64×64 FPGA placement-density experiment (draft)

## Motivation and preserved evidence
P181 #58 successfully synthesized the 64×64 programmed framebuffer shader but nextpnr rejected a validity-bit cell after 10,001 legal-placement attempts. P184 #61 tried to change the `--placer-heap-cell-placement-timeout` divisor (first 100000, then 1). Both exact-head physical jobs failed on the same `valid0_TRELLIS_FF_Q_1511_DI_LUT4_Z` at 10,001 attempts. Raw evidence is available in GitHub Actions for PR #61. Neither P181 nor P184 produced a real 64×64 routed Fmax.

## One-variable hypothesis
On the already-verified, P183-integrated P180 candidate `5d9f6c916fb534d5ecd1de9484c86dbd2519a4c1`, test nextpnr ECP5 **heap placement** with `--placer-heap-beta 0.97` instead of default 0.90 maximum placement density. Higher local placement density might avoid the previous validity-memory hotspot. No change to synthesizable RTL, Vivado-style constraints, 77-pin host interface, Yosys synthesis script, 85K CABGA756 speed-6 target, seed 1, or resource/frequency assertions. Preserve the existing 60-minute CI job timeout; do not use `--timing-allow-fail`.

## Required acceptance and interpretation
- Actual 64×64 ECP5 **placement AND routing** must finish successfully and produce nonzero `route.json` Fmax >=5 MHz, real 77 IO, 7–32 DP16KD BRAM, <=72 MULT18X18D DSP, valid LUT4/FF counts and downloadable logs/artifacts.
- Keep exact-head P180/P183 large-frame pixel oracle, overflow handling, 16×16 >=36.5 MHz, 32×32 Fmax, and 32×64 physical route separate and intact. The P185 job is a *feasibility experiment* and cannot substitute for combined regression CI.
- If this physical experiment fails, do not merge. Report the exact placer error, then investigate a different framebuffer validity representation (e.g. BRAM-backed metadata with an explicitly verified reset/reinitialization contract) instead of repeatedly relaxing acceptance criteria.
- Never treat estimated FPGA MHz as GPU FPS or as a claim of physical gaming-card/RTX-class performance.
