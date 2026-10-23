# P48 — Host-visible frame diagnostic messages (development contract)

## Scope and boundaries

P48 adds a *logical* multiplexed byte stream for P46 command results and
P47 frame signatures. It does not implement PCIe, a physical display output,
DMA, interrupts, driver support, executable shaders, physical VRAM, or a
performance claim. All predecessor P47 and earlier source files are unchanged.

## Host output framing

When the output port is selected, handshaken bytes belong to one complete
packet before any bytes from a different stream may be accepted.

| Packet | Magic at offset 0 | Size | Generator |
|---|---|---:|---|
| Existing command result | ASCII `A0GR` | 16 | P46 |
| New frame telemetry | ASCII `A0GF` | 32 | P48 |

Telemetry frame byte layout (all multibyte fields unsigned little-endian):

| Byte offset | Size | Data |
|---|---:|---|
| 0 | 4 | `A0GF` |
| 4 | 1 | protocol version `1` |
| 5 | 1 | bit0 `frame_error`, all other bits `0` |
| 6 | 2 | event sequence, counts **every** P47 completed frame (mod 65536) |
| 8 | 4 | P47 pixel-stream CRC32 (accepted pixel bytes B, G, R) |
| 12 | 4 | P47 good-frame count |
| 16 | 4 | P47 bad-frame count |
| 20 | 4 | P47 aborted-frame count |
| 24 | 4 | number of *already dropped* telemetry events (saturating) |
| 28 | 4 | CRC32/IEEE on bytes 0–27 |

When P47 produces a one-cycle `frame_valid` pulse, P48 captures the P47
registered status and counter snapshot on the next clock edge. This avoids
reading pre-increment P47 counters. A packet is immutable once captured.

## Backpressure, loss and priority

P48 telemetry transmitter stores **one** 32-byte packet. If another frame
completes while this packet is occupied, the new event is **not queued**:
`dropped_frame_events` saturates at `0xffffffff`. Every completed frame,
including the dropped ones, increments `event_sequence_q` modulo 65536.
The next successfully captured packet reports the cumulative drops. There
is **no lossless telemetry guarantee** at arbitrary scanout frame rates.
On the exact cycle the 32nd byte is accepted, a concurrent new P47 frame event
is counted as dropped, not queued.

P48 arbiter registers a frame-level grant. On IDLE, ready P46 results have
priority over ready P48 telemetry. Once granted, the output is locked to that
source for 16 or 32 handshaken bytes. Source `valid` and `byte` must obey
standard hold-on-stall ready/valid rules. Output backpressure propagates only
to the selected stream. **It never stalls the P47 scanout path.**

Reset aborts all partial packets, clears sequence/loss counters and arbiter
grants. Host software must discard any partial packet after transport reset.

## Observability and security notes

The two protocols use distinct magic and have separate CRC checks; the decoder
fails closed for unknown version/status, malformed header, CRC error, or
truncation. CRC32 detects accidental corruption but is not a cryptographic
integrity or authentication mechanism; untrusted physical transports need
separate security measures. Sequence gaps are diagnostic evidence of loss,
not a mathematically complete proof when the 16-bit sequence wraps.

## Verification requirements

1. Independent software parser/encoder tests against P46 result packets.
2. RTL simulation with P48 telemetry TX TB and arbiter TB.
3. RTL top-level compile/lint for P38–P48 integration.
4. Additional randomized RTL-to-reference differential traces and end-to-end
   host reads before claiming P48 closed.
5. FPGA/device-level validation required before calling it physical GPU I/O.

The first item is executed in this development package. Items 2–5 remain
open until executed and evidenced with actual binaries and logs.
