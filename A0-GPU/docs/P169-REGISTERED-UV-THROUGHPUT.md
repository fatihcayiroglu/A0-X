# P169 — Registered UV interpolation for real FPGA throughput

## P168 baseline (exact ECP5-85K post-route measurement)
- Full P163 programmed fragment host: 77 IO, 5 ECP5 BRAM and 72 DSP.
- Routed Fmax: 21.07 MHz (5 MHz minimum previous release gate).
- Affine: 128 serialized restoring divider clocks per successful covered sample.
- Perspective: 160 restoring divider clocks.

## P169 architecture
Break the long vertex-register -> signed edge difference and multiplier ->
weighted rational products -> 80-bit sum -> 80-bit absolute-value path into
independently clocked stages **without intermediate truncation**:

1. Accept one request and atomically capture 3 P38-compatible signed edges,
   all 6 signed UV-times-inverseW attributes and 3 unsigned inverse-Ws.
2. Compute and register all 6 signed 79-bit weighted products plus all 3
   signed 54-bit weighted denominator terms in parallel.
3. Register exact signed 80-bit U/V numerators and denominator and signed
   36-bit unweighted area.
4. Reject zero area/denominator; convert signed numerators and denominator
   into magnitudes and initialize the shared restoring divider.

Relative to P168 this adds 3 setup clocks for each valid sample:
**131** total divider+setup clocks (affine) and **163** (perspective).
The output protocol (req_id, fault, backpressure, reset), 77-pin host bus,
P162 TEX/ALU, P144 depth/RGB semantics and 64/80 divider iterations remain.

## Hard acceptance gates
- The 4,035-case independent perspective rational oracle tests now poison
  accepted input geometry, UV, inverse-W and pixel coordinates while busy.
  Results must stay tied to the exact handshake snapshot.
- Compare 1,025 signed affine tests bit-for-bit with separately validated
  P164 hardware, including fast success latency of exactly 131 clocks.
- Re-run P163, P165 and P167 full P102 frame/depth/shader integration suites.
- Route the **real** 77-IO P163+P166 host top on the ECP5-85K. Assert
  mapped DSP <=72 and BRAM >=3. Require routed **Fmax >=23 MHz**, a real
  improvement over P168's 21.07MHz. Since clock count rises by 3, this
  implies at least 6% measured lower per-sample latency in nanoseconds
  for both affine and perspective (without claiming GPU-level FPS).

No board, physical PCIe link, GDDR/HBM, driver stack, games, or real-world
RTX-class benchmark is implemented in this milestone.
