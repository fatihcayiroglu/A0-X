# P144 — dual-lane depth test and RGB blend with real two-bank BRAM

**Status: draft**. Separate, bounded research RMW block, NOT wired to the P143 dual triangle scan yet.

P144 combines P139/P138's actual two independent ECP5 RAM banks with **two real instances of P68 depth compare and two P135 exact 8-bit RGB blend units**. One packet supplies up to two framebuffer XY coordinates, common source color/depth and depth/blend settings, and a lane-valid mask. Accepted packets go through one synchronous read beat, followed by a simultaneous conditional write beat; both lanes finish in two clock cycles. Valid packets must target distinct banks (linear framebuffer index parity). Same-bank pairs, out-of-range X/Y, and masked invalid-lane issues are handled deterministically: malformed pairs are rejected as a whole, with **zero writes** and a visible error pulse. No partial success is silently accepted.

The special `op_clear` mode directly overwrites full 48-bit color+depth words in one clock for up to two lanes. Reset aborts an in-flight packet, invalidates P138 storage metadata, and flushes responses; the host readback port shares lane 0 only during idle. Host requests are backpressured behind active RMW packets; op requests have priority over simultaneous host requests. The public `rsp_valid` signal is a one-cycle registered pulse with **no response-ready**; consumers must capture it.

The depth compare modes match P68: 0 ALWAYS, 1 LESS, 2 LESS_EQUAL, 3 FAIL CLOSED (no write). RGB blending matches exact P135 integer rounding (source*alpha + destination*(255-alpha)+127)/255 per channel. When depth writing is disabled, the previous 24-bit stored depth survives an accepted color update.

## Required before safe integration

- Real Icarus RTL simulation on 4x4, 7x5, 8x8, 32x32. Independent golden full-frame RGB/depth array (not mirror of memory internals), test ≥450 transactions, ≥300 dual requests, depth rejections, alpha=0/127/255, depth-write disabled, invalid XY, ≥32 same-bank conflicts, all pixel readback, reset during outstanding read. A correctly rejected packet must not update either lane.
- Actual Yosys `synth_ecp5`, nextpnr ECP5-85K on 4x4 with CABGA756/speed6/seed1, 5MHz artificial internal timing target and unconstrained external pins. Assert ≥2 real mapped `DP16KD`, bounded IO/resource utilization, no unmapped cells/latches, actual Fmax report. Do NOT compare standalone P144 Fmax to P143 integrated raster Fmax as if they were identical tops.
- All inherited workflows on exact PR head must stay green. **Do not merge if any expected job is absent, pending, failed or skipped.**

## Limitations and next steps

P144 proves two simultaneous *depth-tested, alpha-blended framebuffer RMW lanes*, NOT two independently shaded pixels within the triangle pipeline. The actual P143 raster is still opaque-only; integrating its two edge candidates into P144, preserving asynchronous host/command contracts, ordering, stalls and end-of-draw accounting is a subsequent step. No complete shader, texture system, board-level VRAM, PCIe, display driver, device timing or FPS evidence.
