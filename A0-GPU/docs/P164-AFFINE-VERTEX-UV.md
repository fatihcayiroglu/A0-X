# P164 — Signed vertex UV interpolation with exact integer barycentrics

P163 currently maps textures with a per-draw signed Q8.8 UV offset from
screen pixel XY; it has no per-vertex attributes. P164 implements the
**standalone mathematical hardware primitive** needed for this upgrade:
interpolate three independent vertex U/V attributes at a pixel center using
edge-function barycentric weights matching the P38 integer rasterizer.

This standalone version must pass real Icarus and ECP5 routing *before*
being connected to the P163 shader's R0 coordinate loading. That integration
is a following milestone; P164 does not yet replace P163's screen UVs.

## Precise signed fixed-point contract

- Vertex positions `x0/y0 ... x2/y2`, and integer pixel XY, use P38's
  signed integer pixel-coordinate convention. Pixel center is `(x+0.5,
  y+0.5)`. Vertex attributes `u0/v0 ... u2/v2` are signed 16-bit **Q8.8
  texel coordinates**, not normalized UV, not perspective divided.
- Compute the oriented signed doubled edge areas E0/E1/E2 opposite each
  vertex. The signed denominator is E0+E1+E2, independent of pixel location.
- Each output is an exact rational integer truncating toward zero:
  `U = trunc((E0*U0 + E1*U1 + E2*U2)/(E0+E1+E2))`; likewise V.
  Clockwise triangles produce the same UV for the same mapped vertices.
- One division unit performs **64 restoring steps for U and 64 for V**.
  No unsized synthesizer `/` operator or floating point, no approximated
  reciprocal. No inferred large combinational divider or feedback loop.
- Zero-area triangles return `rsp_error=1` with U=V=0. Extrapolation outside
  the triangle that mathematically exceeds signed 16-bit Q8.8 also fails
  closed instead of wrapping. A response carries the original 8-bit tag;
  stalled responses hold UV, fault and ID stable. Reset aborts in-flight
  interpolation; one request at a time, no speculative pipeline.

## Proof gates

Actual Icarus runs **1,010** samples across 7 triangle geometries × 4
attribute patterns × 36 pixels plus overflow and post-reset checks. All
successful UVs match an **independent 64-bit signed scalar cross-product
and native integer-division reference** exactly, including negative
coordinates, clockwise/counterclockwise winding, and signed non-integer
texel fractions. Confirm zero-area/overflow rejection, 3-cycle response
backpressure holds, 8-bit tags and in-flight reset discard.

Real Yosys and nextpnr ECP5-85K CABGA756 speed6 seed1 must fully route
the **279-IO standalone module** at the 5 MHz unconstrained external pins
research target, mapping actual DSP multipliers and serial register/control
logic. This is tool evidence only; it does not imply a board or gaming FPS.

The next integration step should snapshot vertex geometry/UV on triangle
launch, compute P164 signed UV per P38-covered fragment, add the chosen
uniform offset and drive P163/P162 R0 before executing the shader program.
That integration must be tested against full RGB/depth P102, clamp/repeat,
missing-tap fail-closed semantics and a *new* full-top routed FPGA report.
Later, reciprocal W and perspective-correct interpolation remain separate
work; affine UV is insufficient for general 3D projection.
