# P187: recover 32x64 physical timing with full-clear guard (draft)

## Existing exact-head evidence
P186 PR #63 head `bfa19f3c1400028e69bbed4a9e410270299abb0c` passed all 15 top-level workflows, including a genuine 64x64 ECP5 route at 42.59 MHz (77 IO, 13 BRAM, 72 DSP). Nevertheless its real P179 32x64 route clock was **27.72 MHz**, below the P180 base head `5d9f6c9` **30.17 MHz** (about -8.1%). Both results used the same ECP5 85K CABGA756 speed-6 device and seed 1. This regression is visible even though both existing 5 MHz feasibility floors pass.

## One-variable RTL hypothesis
The P175 integrated programmable renderer already writes *every* pixel on accepted clear and refuses drawing/host reads until all clear responses succeed. P186's registered full-frame initialized guard specializes only >=4096 pixels. Lower that elaboration threshold to **2048 pixels**, enabling the same mechanism for 32x64 without changing the default per-pixel validity contract of standalone P138/P139/P144 clients. No change to arbitration, pixel BRAM data, reset/clear ordering, test timeouts or previous 16x16/32x32 behavior. This should remove approximately 2048 resettable validity FFs from 32x64 and may recover physical timing. It is a hypothesis until actual place+route passes.

## Required exact-head proof
1. New 32x64 Icarus RTL guard test proves stale data masked before full initialization, visible after full initialization, masked after frame invalidation and reset. Keep the P186 64x64 guard test and older standalone default regression.
2. All P178/P180 independent full-frame pixel, depth, reset, overflow, shader instructions and cycle oracles for asymmetric and large geometry. No skips, retries or time-limit increases.
3. Genuine P187 32x64 Yosys+nextpnr route with unchanged seed/device/77 IO/BRAM/DSP evidence, fewer than 7,146 FF and 23,845 LUT4 from P186, and **actual route Fmax >=30.17 MHz** (P180 32x64 baseline). Retain failed raw evidence if it misses the ratchet.
4. Unchanged P172 16x16 >=36.5 MHz, P177 32x32, P179 32x64 and P186 64x64 physical routes must all complete at exact head without unreported performance regressions.
5. Keep draft; merge only into the stacked P186/P180 candidate after all checks, evidence, review and head/base verification. This is not a commercial card or FPS claim.
