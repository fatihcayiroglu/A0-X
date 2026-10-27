# P186: bounded full-clear validity specialization (draft)

## Reproduced blocker
P185 #62 (exact head e50b385a00a4edff6efe98a8bda8eb905b91e712, Actions run 40566805663) successfully synthesized the 64x64 ECP5 programmable host (77 IO, 13 BRAM, 72 DSP, 37,983 Yosys LUT4, 9,195 FF) but failed physical placement on `core.framebuffer.banks.storage.valid0_TRELLIS_FF_Q_1511_DI_LUT4_Z` after 10,001 attempts. P181, P184 and P185 do **not** provide a routed 64x64 Fmax. Logs and downloadable failed artifacts remain intact.

## A separate RTL hypothesis
Keep all standalone P138/P139/P144 callers unchanged by default: per-pixel resettable validity bits ensure unwritten reads return zero. Only the P175 integrated programmable framebuffer at >=4096 pixels opts into `FULL_CLEAR_GUARD`. That engine already serially clears **every** pixel through no-read write transactions, confirms each response, and refuses host reads or drawing until the final clear has been acknowledged. It resets `initialized_q` on reset and when a new clear starts. Propagate `initialized_q` to the framebuffer as `frame_initialized`, and sample it on accepted reads. Before it is true, responses remain deterministic zero, even when BRAM contains stale contents. Once true, the bank data is valid at every address, so no 4096-bit validity bitmap is needed for 64x64. When reset/re-clearing, the guard is withdrawn.

This is a *protocol-dependent specialization*, not a universally safe optimization for arbitrary partial writes. The standalone default retains its previous semantics. The compile-time opt-in is prohibited below 4096 pixels.

## Required honest tests
1. Directed real Icarus guard test: nonzero write/read is masked before initialization, visible after the guard is asserted, masked on deinitialization and after reset.
2. Unmodified P138/P139/P144 legacy regression and independently checked P178/P180 64x64 through 128x128 full-frame color/depth/overflow/latency oracle, including reset/missing-init failures. Existing path filters must fire; do not weaken, skip, or lengthen tests.
3. Unchanged 16x16 >=36.5 MHz physical ratchet and 32x32 / 32x64 physical regression, no meaningful unreported regressions.
4. Actual 64x64 Yosys+nextpnr 85K CABGA756 speed-6, seed1, default heap placement, no timing waiver: 77 IO, 7..32 BRAM, 40..72 DSP, fewer than P185's 9,195 FF, fully routed `route.json` clock >=5 MHz, and surviving artifacts including failures.
5. Keep this stacked PR draft and out of production main until all **exact-head** jobs pass and integration is reviewed. If the physical attempt fails, preserve the raw failure and do not merge.

A 5 MHz FPGA research feasibility floor is not a GPU gaming or RTX-class performance claim.
