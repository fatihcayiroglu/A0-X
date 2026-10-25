# P161 — fully configurable 76-bit textured graphics research command bus

P160's unrestricted parallel interface used 439 FPGA pins; the P160 fit wrapper
had to hold some controls constant to fit ECP5 CABGA756. P161 instead uses
**76 actual RTL I/O bits** to program the full P160 functionality through a
single-clock 5-bit-address, 32-bit-data register/command bus. No separate
fixed depth, shader alpha or texture mode restrictions are required.

The underlying active path remains real P38 raster → P159/P158/P156 bilinear
BRAM → P150 UNORM SIMD4 → P144 dual-bank RGB/depth BRAM RMW. P161 changes
host **transport and command snapshots**, not shader semantics.

## Host register map

| Addr | Register | Encoding |
|---:|---|---|
| 0–2 | CLEAR_RGB, CLEAR_DEPTH, TRI_DEPTH | low 24 bits |
| 3–5 | V0, V1, V2 | signed Y in [31:16], X in [15:0] |
| 6 | UV_OFFSET | signed Q8.8 V in [31:16], U in [15:0] |
| 7 | SHADER_B | full RGBA operand B |
| 8 | SHADER_MODE | bits 0–1 depth op, 2 depth write, 3 blend, 4 repeat, 8–15 source alpha, 16–18 SIMD opcode, 19–22 lane mask, 23–30 shader alpha |
| 9 | FB_MODE | reserved, reject writes |
| 10 | READ_XY | host pixel Y in [31:16], X in [15:0] |
| 11 | TEXTURE_XY | texel Y in [7:4], X in [3:0], upper bits zero |
| 12 | TEXTURE_RGBA | write full RGBA into selected texel (only if texture idle) |
| 13 | COMMAND | 1 clear, 2 triangle, 3 host pixel read |
| 14 | STATUS | initialized bit0, busy1, fault2, clear done3, triangle done4, pixel cached5, clear-ready6, tri-ready7, texture-ready8, host-ready9, read-pending10 |
| 15–16 | PIXEL_RGB, PIXEL_DEPTH | cached true P144 host BRAM result after command3 |
| 17 | IDENT | `A0161001` |
| 18–20 | SHADED_COUNT, LAST_RGB, TEX_WRITES | telemetry |

Writes to malformed/reserved addresses fail without changing configuration.
Clear/triangle commands return immediate acceptance, and completion must be
polled via sticky bits. Pixel read command3 defers its reply until **real
BRAM** returns. The host cannot post another request while a reply is pending.
Only one core texture lookup/shader/RMW packet is in flight.

## Strict evidence requirements

Actual Icarus must verify at least 256 live texture writes through the host
register protocol, full-frame color/depth against unchanged P102 and an
independent scalar bilinear+UNORM oracle for two distinct clamp/repeat modes,
plus rejected malformed/unsupported commands and complete response ordering.

Actual Yosys `synth_ecp5` + nextpnr ECP5-85K CABGA756 speed6 seed1 must
fully route **exactly 76 I/O bits**, genuine `DP16KD` texture and framebuffer
BRAM, and FPGA DSP arithmetic. The 5 MHz timing target uses unconstrained
external pins; results are not board measurements, PCIe, a driver, a mature
shader `TEX` ISA or gaming FPS evidence. The P160 screen-space Q8.8 offset
is not perspective-correct vertex UV interpolation.
