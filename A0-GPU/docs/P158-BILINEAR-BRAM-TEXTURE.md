# P158 — four-tap bilinear RGBA8 texture with real P156 synchronous BRAM

P158 wraps the **unchanged P156 16×16 nearest-texture BRAM**, issuing four
serialized texture reads per bilinear lookup. Each accepted request produces
one tagged response with a 32-bit RGBA8 value and a `rsp_present` bit. Writes
are accepted only while idle. Simultaneous new sample/write contention favors
the sample; the write is refused. No write can interleave with the four reads.

## Exact fixed-point contract

- `sample_u` and `sample_v` are **signed Q8.8 texel indices**, not normalized
  0–1 UVs: floor is an arithmetic shift right by 8, fraction is the low byte.
- Four texels are `(floor(u),floor(v))`, `(floor(u)+1,floor(v))`,
  `(floor(u),floor(v)+1)`, `(floor(u)+1,floor(v)+1)`. Every tap independently
  uses P156 clamp or power-of-two repeat addressing.
- For each of four RGBA channels, interpolate the horizontal pair twice using
  `round_nearest((a*(256-f)+b*f)/256)` (implemented with integer `+128` then
  right shift 8), then interpolate the two intermediate results vertically.
  This deliberately **rounds at each axis**, rather than performing one
  32-bit single-rounding weighted sum.
- Unwritten texels contribute exactly zero, hiding uninitialized BRAM data.
  Presence is false only when a **nonzero-weight** tap was never initialized;
  zero-weight neighbors are irrelevant. Presence remains separately reported
  from color, which may be nonzero if some contributing texels were present.
- Only one bilinear request is in flight. `sample_ready` is low throughout its
  four reads and output hold. Response tag, RGBA, valid and presence remain
  stable through arbitrary `rsp_ready=0` stalls. Reset discards in-flight
  requests and clears the underlying P156 valid-texel map, not raw BRAM.

## Required proof before integration

The new `.github/workflows/a0-p158-bilinear-texture.yml` runs real Icarus
RTL against an independent signed integer Q8.8 oracle, covering sparse and
fully initialized textures, clamp/repeat, exact two-pass channel rounding,
input write/read collision, output backpressure and reset. It also requires
real Yosys `synth_ecp5` and nextpnr route with at least one genuine `DP16KD`
BRAM, no unresolved cells or latches, and a 5 MHz **tool target** on an ECP5
85K CABGA756 speed6 FPGA with unconstrained physical pins. The tool result is
not a tested board clock. Logs must be retained on failures.

P158 does **not** yet implement mipmaps, trilinear/anisotropic sampling,
normalized coordinates, derivatives/LOD, a shader `TEX` instruction,
VRAM/cache traffic or framebuffer attachment. It is not ASIC, PCIe,
driver or real game/RTX-class performance evidence.
