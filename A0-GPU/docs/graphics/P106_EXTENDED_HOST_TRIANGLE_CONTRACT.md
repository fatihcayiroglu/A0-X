# P106 experimental host fragment-state wire contract

**Status: development-only; RTL compilation/simulation, FPGA, PCIe and device validation NOT achieved.**

P106 is a *backwards compatible* logical extension of the P44 command byte protocol. It does not change existing V1 frames and does not add physical PCIe or DMA support.

| Property | V1 (P44/P45 legacy) | V2 (P106) |
|---|---|---|
| Magic | `A0GC` | `A0GC` |
| Byte 4 | `01` | `02` |
| Opcodes | CLEAR(0), TRIANGLE(1), PRESENT(2), INVALID(3) | **TRIANGLE(1) only** |
| Record length | 32 bytes | 56 bytes |
| CRC32/IEEE | bytes 0–27, little-endian at 28–31 | bytes 0–51, little-endian at 52–55 |

## V2 fixed-length command bytes

| Offset | Size | Description |
|---|---:|---|
| 0–3 | 4 | ASCII `A0GC` |
| 4 | 1 | Version 2 |
| 5 | 1 | Opcode **1** (`TRIANGLE`) |
| 6–7 | 2 | Tag, little-endian unsigned16 |
| 8–11 | 4 | Color RGB888 in low 24 bits; top 8 bits MUST be zero |
| 12–23 | 12 | Six signed16 x0,y0,x1,y1,x2,y2, little endian |
| 24–27 | 4 | Reserved **zero** |
| 28–31 | 4 | Depth unsigned24 low bits; top 8 bits MUST be zero |
| 32 | 1 | Flags: bits 0–1 depth compare (0 ALWAYS, 1 LESS, 2 LEQUAL, 3 NEVER); bit2 depth write; bit3 alpha blending; bit4 scissor enable; bits5–7 **zero** |
| 33 | 1 | Source alpha unsigned8 (0–255) |
| 34–35 | 2 | Reserved **zero** |
| 36–43 | 8 | Four unsigned16 scissor x,y,width,height, little endian. MUST all be zero when disabled; when enabled width and height MUST be nonzero |
| 44–51 | 8 | Reserved **zero** |
| 52–55 | 4 | Standard reflected CRC32/IEEE of bytes 0–51, little endian |

For V1, per-command fragment defaults are **depth=0xFFFFFF, depth op=ALWAYS, depth_write=0, blend=0, alpha=255, scissor disabled**, including when V1 follows a V2 packet. CRC and canonical field checks happen before command dispatch. The receiver exposes exactly one decoded command until acknowledged by the graphics frontend; this prevents the state from changing during a command. Invalid wire packets are silently discarded (and counted when detected), **not** ACKed. Framing loss and corrupted streams cannot guarantee exactly-once delivery.

The P104 dual bank keeps per-command fragment state and writes only the rear bank, while P47 CRC monitors accepted front-bank pixels. P46 results and P48 telemetry share P49's packet-atomic fair host mux. **P48 can drop frame telemetry under backpressure**; an absent frame record is not proof the rendered frame was correct.

## Reproducible software tests and hardware gate

From `A0-GPU/`:

```bash
python3 -m unittest discover -s tests -p 'test_p106_*.py' -q
python3 -m unittest discover -s tests -p 'test_*.py' -q
python3 tools/a0_host_triangle_p106.py encode --spec examples/p106/triangle.json --output /tmp/a0-triangle-v2.bin
python3 tools/a0_host_triangle_p106.py inspect --input /tmp/a0-triangle-v2.bin
python3 tests/run_p106_extended_host.py
```

The RTL gate requires `iverilog` and `vvp`; absent tools return **2 (NOT RUN)**, compiler/simulation failures return **1**, and only an actual simulation reaching `P106_REAL_RTL_PASS` can return **0**. The HDL bench sends a legacy CLEAR, an extended triangle with scissor and blending, deliberately corrupts an extended packet, sends legacy PRESENT, and checks a 4x4 pixel stream, CRC32 and result records. The fixture's RGB expectation is cross-checked by a Python pixel model; the HDL bench itself remains **unexecuted** in this build environment.

No shader binary, driver API, general command processor state machine, concurrency guarantee, PCIe, physical VRAM, video PHY, FPGA or ASIC silicon has been implemented or qualified in P106.
