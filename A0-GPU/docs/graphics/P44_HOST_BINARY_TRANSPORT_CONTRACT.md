# P44 — software-only host command transport, version 1

**Status:** Python reference model tested; **NOT** RTL/PCIe/DMA hardware verified.

This is an opt-in host protocol that serializes existing P43 CLEAR / TRIANGLE /
PRESENT / INVALID operations. It does **not** change the original P43 SystemVerilog
frontend or claim that a hardware receiver for this framing already exists.

## Command frame (32 bytes, little-endian)

| Offset | Length | Type | Meaning |
|---|---:|---|---|
| 0 | 4 | ASCII | `A0GC` magic |
| 4 | 1 | uint8 | version=1 |
| 5 | 1 | uint8 | opcode: CLEAR=0, TRIANGLE=1, PRESENT=2, INVALID=3 |
| 6 | 2 | uint16 LE | host-assigned tag |
| 8 | 4 | uint32 LE | RGB888 color, upper 8 bits **must be zero** |
| 12 | 12 | six signed int16 LE | (x0,y0,x1,y1,x2,y2) |
| 24 | 4 | uint32 LE | reserved, **must be zero** |
| 28 | 4 | uint32 LE | CRC32 of bytes 0..27 (standard IEEE/zlib) |

For CLEAR, vertex bytes must all be zero. For PRESENT and INVALID, both color
and vertices must be zero. Unsupported versions, noncanonical payloads, bad
magic and CRC fail closed (not dispatched). A malformed packet does not produce
a result, because its tag cannot safely be trusted. A streaming decoder may
resynchronize at the next `A0GC` marker; it records invalid frames and bytes
it dropped. CRC32 detects accidental corruption, **not adversarial tampering**.

## Result frame (16 bytes, little-endian)

| Offset | Length | Type | Meaning |
|---|---:|---|---|
| 0 | 4 | ASCII | `A0GR` |
| 4 | 1 | uint8 | version=1 |
| 5 | 1 | uint8 | status: OK=0, COMMAND_ERROR=1, TIMEOUT=2 |
| 6 | 2 | uint16 LE | completed tag |
| 8 | 4 | uint32 LE | Python model cycle count, **not device clock cycles** |
| 12 | 4 | uint32 LE | CRC32 over bytes 0..11 |

A command receives at most one result when admitted. Calls are serialized and
completed in source order by this Python mock transport. TIMEOUT fails closed:
all further device requests require constructing a new device instance. No
interrupt handling, retransmission, exactly-once guarantee across resets, or
bus framing exists. Commands are not transactional; previous successful
commands are not rolled back if a later command errors.

## JSON script / CLI

```bash
cd A0-GPU
python tools/a0_host_p44.py --script examples/p44_triangle.json \
    --output /tmp/a0-p44.png --receipt /tmp/a0-p44-receipt.json
python -m unittest discover -s tests -p 'test_*py' -v
```

A script has exactly `width`, `height`, `commands`; a command must have `op`
and `tag`, plus `color` for CLEAR/TRIANGLE and three `[x,y]` pairs for TRIANGLE.
Only unique 16-bit tags are accepted **within a script** to keep receipts
unambiguous. Color may be `#RRGGBB` or a 24-bit integer. The script is fully
validated before execution. Resolutions are bounded by the existing P42 model:
`width*height <= 65536`. This Python model requires at most 1 MiB JSON input
and 10,000 commands per playback.

Exit code 0 means all commands returned OK, 1 means a valid command returned
COMMAND_ERROR or TIMEOUT, 2 means input or runtime failure. JSON receipt is
explicitly marked `P44_SOFTWARE_REFERENCE_ONLY` and includes image RGB SHA256.
Optional PNG is encoded by the standard library and contains the currently
visible/PRESENTed framebuffer, not a captured GPU, RTL or display device frame.

## Missing pieces

- RTL decoder/packet bridge and handshake differential verification.
- Real HDL simulation of P37–P43 including resets under backpressure.
- Coherent connection to P37 memory fabric; currently uses dedicated P42 RAM.
- CPU command queue, shader ISA bridge, proper texture/depth/pixel shading.
- GPU kernel driver, PCIe MMIO/DMA, security boundary and production graphics API.

These are needed for a mature computer-only GPU **design**, even though physical
chip fabrication is out of scope.
