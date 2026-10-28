# P210: frame-boundary-fenced abstract pixel stream

P209 delivers a *real independent* single-clock 48-bit pixel read port from
two actual mirrored ECP5 EBR banks, with per-pixel 32-bit epoch. Without a
frame boundary contract, the published bank could change halfway through a
continuous readout stream. P210 wraps the **unchanged complete P209→P203**
producer and scanout with a hardware **ready/valid pixel streamer** and a
publication commit barrier at the last pixel of a frame.

## Physical protocol

- Original host byte register API and P208 frame coverage are preserved.
  Host write `0x31=0x01` is now **queued** by P210; it is not forwarded
  to P208 until the existing displayed frame's last output pixel has
  been **accepted** with `pixel_valid && pixel_ready`.
- The first fully committed frame publishes immediately when no front exists.
  Later publications may be queued during any ongoing frame. Producer
  writes are held once publication is queued; read-only status queries
  remain possible. Invalid or incomplete publication fails closed when
  P208 checks it; no unverified data is scanned out.
- P210 reads all `WORDS` pixels in order from P209's **physical shadow EBR**
  using its request and registered response protocol. The pixel stream
  holds the current index, 48-bit data and epoch stable under backpressure
  until `pixel_ready` is asserted.
- Last-pixel consumer acceptance is the *only* boundary on which the
  queued front switch may begin. P210 pauses its scanout request stream,
  forwards the queued P208/P209 publication command, waits for the
  underlying epoch-scoped scanout bank transition, and resumes at word 0.
  The first new word belongs to the new epoch. An invalid or timed-out
  handoff causes a sticky fault.
- Every single completed output frame is thus tagged by one consistent
  epoch in this **single-clock abstract stream**. Concurrent producer
  writes to the back bank do not affect the published front pixels.
  A new publish request that arrives after the current frame boundary is
  deferred until the next safe boundary.

## Stream and pin budget

The new top keeps the 29-bit producer host bus and exposes:

| Signal | Direction | Bits |
| --- | --- | ---: |
| `pixel_ready` | Input | 1 |
| `pixel_valid` | Output | 1 |
| `pixel_data` | Output | 48 |
| `pixel_index` | Output | 10 |
| `pixel_epoch` | Output | 32 |
| `frame_start`, `frame_end` | Output | 2 |

**Total 123 I/O bits** (29 producer plus 94 pixel-stream bits). Start/end
are qualifiers valid while the corresponding pixel is presented; a
consumer accepts them only when `pixel_valid && pixel_ready` is true.

## Test and physical proof contract

- Real Icarus simulation at `WORDS=8` and `WORDS=1024` with two complete
  committed frame payloads in real EBR storage. Producer writes the
  second bank while the first is streaming. The consumer holds the last
  pixel indefinitely until the second publish has queued; its word,
  `frame_end` and epoch must remain immutable. Only after consuming
  that pixel does the first word of epoch 2 become visible. Premature
  one-address publish is rejected; reset scrubs all shadow and primary
  banks, and published front writes remain forbidden.
- Re-run all inherited P175/P203/P205/P206/P207/P208/P209 exact-head
  integration/negative tests, including default-size physical memory.
- Require actual Yosys ECP5 synthesis and `nextpnr-ecp5 --85k
  --package CABGA381 --speed 6 --freq 10` route, exactly **123 pins**,
  at least **12 DP16KD** for the four real RAM banks, nonzero LUT4/FF,
  zero unmapped cells/latches/blackboxes and real routed Fmax ≥10 MHz.
  Preserve failures and artifacts, zero skips/retries/waivers.

## What this does NOT claim

P210 provides a **safe abstract ready/valid word stream**, not a standards-
timed raster output. It has no pixel-clock generator, horizontal or
vertical blanking, HDMI/DisplayPort serializer, dual-clock CDC, actual
monitor connection, off-chip VRAM, PCIe, board LPF/pin assignment, silicon
timing, production GPU driver or FPS evidence. Its one-outstanding-read
state machine is not yet a high-bandwidth pipelined video DMA. The next
steps must address timing generators, deeper pipelining, and real board
interfaces before claiming visible output.
