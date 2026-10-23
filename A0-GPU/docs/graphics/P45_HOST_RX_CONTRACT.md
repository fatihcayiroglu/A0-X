# P45 — experimental P44 host-byte to P43 command RTL receiver

**Scope:** This development layer adds an *unexecuted* SystemVerilog implementation proposal for the receive half of the P44 binary host protocol. It is **not** PCIe, DMA, a complete bidirectional host bridge, a production driver, or evidence of physical GPU execution.

## Interface

- `in_valid/in_ready/in_byte`: one wire-protocol byte accepted on each rising clock edge when both handshakes are high. Bytes can pause at any point.
- `cmd_valid/cmd_ready`: one P43 command offered after all 32 bytes of a valid frame have been received. The decoded opcode, tag, RGB and six signed 16-bit vertex coordinates are held stable until accepted.
- `invalid_frame_count`: saturating 32-bit diagnostic counter for complete 32-byte windows beginning with `A0GC` that fail validation. This is not a count of all noise bytes.
- A single held command blocks all further ingress; once the command is accepted the receive window is cleared. No hardware FIFO or command queue is claimed.
- Active-low **synchronous** reset cancels partial frames, a held command and diagnostic counters. The sender must be reset/drained coherently; reset does not guarantee exactly-once delivery across reconnects.

## Exact validation (little-endian)

Candidate window: bytes 0–3 ASCII `A0GC`; byte 4 version 1; byte 5 opcode 0..3; bytes 6–7 tag; bytes 8–10 color; byte 11 zero; bytes 12–23 signed coordinates; bytes 24–27 all zero; bytes 28–31 CRC32(0..27). An opcode other than TRIANGLE requires all vertex bytes zero; PRESENT/INVALID additionally require zero color.

CRC32 is reflected IEEE polynomial `0xEDB88320`, initial `0xFFFFFFFF`, final bitwise complement. P45 RTL calculates CRC for the entire 28-byte header combinationally. This is a **prototype**, not timing-qualified silicon; combinational CRC depth must be re-evaluated before timing closure.

## Recovery

The receiver samples successive **sliding 32-byte windows** until it identifies a valid frame. A bad frame candidate cannot become a command even if its magic/version are intact; input bytes are retained for potential overlapping recovery. This can recover a valid frame whose magic starts inside a corrupt stream, but malformed input creates no error completion (its tag is untrusted). The receiver does not implement cryptographic authentication or protection from malicious hosts.

## Required validation before claiming hardware functionality

```bash
cd A0-GPU
python -m unittest discover -s tests -p 'test_*py' -v
python tests/run_p45_host_rx.py
```

The first command tests **Python models**, including a separate clock-step reference of the P45 receiver. The second command compiles and runs the actual SystemVerilog testbench using Icarus (preferred) or Verilator if installed. It returns exit **2** if no full HDL simulator exists; exit **2** is a BLOCKER, never a pass.

After successful RTL simulation, extend with independent differential tests against exact P44 wire vectors, randomized flow-control and reset, deeper formal invariants, and a real P43 frontend integration. Receiver-only P45 does not emit result frames; a future TX module and end-to-end test are still needed.
