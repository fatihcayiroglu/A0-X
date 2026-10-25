# P166 — Perspective-correct per-vertex UV interpolation

Status: real standalone synthesizable RTL, **not yet connected to the P165 programmable fragment pipeline**. No fabricated graphics-card, PCIe, VRAM, driver or RTX gaming claims.

## Exact perspective-correct rational calculation

P166 accepts three signed integer pixel-space vertices, their signed Q8.8 UV texture attributes, **three strictly positive unsigned inverse-W** values in a common fixed-point scale (such as Q4.12), and a raster pixel center.

Signed P38-compatible barycentric edge weights are `e0,e1,e2`. Instead of affine `sum(e*u)/sum(e)`, it computes:

```text
U_Q8.8 = trunc_toward_zero( sum(e_i * inverseW_i * U_i) / sum(e_i * inverseW_i) )
V_Q8.8 = trunc_toward_zero( sum(e_i * inverseW_i * V_i) / sum(e_i * inverseW_i) )
```

This is equivalent to interpolating U/W, V/W, and 1/W and dividing, **without rounding each intermediate value**. Any identical scaling of all three `inverseW_i` cancels. The signed numerator is up to 80 bits; products explicitly zero-extend unsigned inverse-W to avoid accidental negative values above 32767. The shared weighted denominator supports either triangle winding. Each quotient is computed using an 80-step restoring divider: two serialized divisions per accepted sample, exact truncation toward zero.

## Fail-closed and handshake guarantees

- Zero triangle area, zero denominator, any zero inverse-W, and results outside signed 16-bit Q8.8 are rejected: `rsp_error=1`, U=V=0.
- One request at a time; `req_id` passes unchanged to `rsp_id`. No overlapping request is accepted while busy.
- Responses and error codes remain stable during arbitrary output backpressure.
- Reset aborts any active division and clears valid/output/error state.
- Pixel samples may extrapolate outside triangle; unrepresentable output still fails closed. P38 coverage gating remains a job for future integration.

## Evidence

- Independent SystemVerilog scalar signed-64 rational cross-product oracle over small bounded fixtures: both winding orders, asymmetric weights, extreme valid unsigned weights, all-zero rejection cases, signed UV and output backpressure.
- Extreme-geometry invariant that **forces weighted intermediate products wider than 64 bits** while all UV coordinates are identical: result must equal the identical signed input exactly. This validates real wide datapath without relying on a narrower software oracle.
- Real Icarus simulator required; Icarus pass marker with 4,035 tagged cases.
- Real Yosys `synth_ecp5` and nextpnr ECP5-85K CABGA756 speed6 full placement/routing at 5MHz research target; explicit IO/DSP, no unresolved primitives or latches; CI evidence uploaded on pass/fail.

## Next: P167 integration

Add optional P166 perspective mode to the **existing 77-pin** packed P165 host bus using spare register addresses for three inverse-Ws. Snapshot all attributes per draw, route tagged per-fragment P166 U/V to shader R0 through the existing UV-offset overflow guard, preserve modes 0/1, and add an independent full P102 depth/RGB oracle on actual TEX/ALU results. Integration is not complete merely because this standalone block passes its checks.

This is a functional raster/texture correctness milestone. It provides no basis for a comparison to RTX 6090 performance.
