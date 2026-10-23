# P107 — Mixed-version host batch / strict capture audit

**Status: Python reference & host tooling only.** No hardware execution or RTL qualification follows from this document.

## Objective

Enable reproducible, multiple-frame host workloads containing P44 v1 and P106 v2 `TRIANGLE` commands without changing either wire packet format. Compile a user-authored JSON plan into the exact outgoing `A0GC` bytes, then audit a captured `A0GR` / `A0GF` byte stream against **independently supplied** expected image CRCs.

## Input, epoch and limits

- Schema is exactly `A0-P107-SESSION-v1`: top-level JSON keys `schema`, `width`, `height`, `reset_epoch`, `frames`.
- `reset_epoch` must be JSON `true`. This is a **precondition asserted by the user**; the code cannot detect an actual device reset.
- One to 128 frames; geometry `1..32767` each, at most 65,536 pixels; maximum 4,096 commands; tag range u16 with no repeated tags in the epoch.
- Each frame has one v1 CLEAR, zero or more v1/v2 TRIANGLEs, and one v1 PRESENT. Additional opcode types and implicit state are rejected.
- v2 draws require exact fragment fields; canonical constraints are delegated to the frozen P106 encoder and checked on roundtrip. v1 draws forbid v2-only settings.
- Each frame **must** provide `expected_crc32` (u32 or `0x` + eight hex digits). The tools do not calculate it from the capture or automatically run a reference renderer. For actual independent evidence, generate this CRC with an external golden-image producer that does not share the implementation under test.

## Audit policy

- The caller must provide the actual intended command file (`--sent-wire`). Its content must exactly match the compiled plan. This is a file-level check, **not** cryptographic authentication of physical transmission.
- The capture must be an exact concatenation of canonical CRC-protected P46 16-byte `A0GR` and P48 32-byte `A0GF` packets. Garbage, truncated packets, CRC failures and extra bytes fail closed.
- Packet ordering between result and frame lanes may vary. Within each lane, results must match all command tags in order, every result status must be success, and frames must match external golden CRCs in order.
- In a fresh reset epoch, frame #i must have sequence `i modulo 65536`, good counter `i+1`, bad/aborted/dropped counters zero, and error false. More or fewer result/frame packets fail.
- Failure, telemetry queue overflow, capture loss, unknown reset or counter wrap ambiguity means *no certification*, not an assumed successful GPU run.

## Usage

```bash
cd A0-GPU
python3 tools/a0_p107_session.py build --plan examples/p107/session.json \
  --wire /tmp/a0_commands.bin --manifest /tmp/a0_command_manifest.json
# Separately send /tmp/a0_commands.bin over a future real transport and capture
# the device's A0GR/A0GF bytes into /tmp/a0_capture.bin, if supported.
python3 tools/a0_p107_session.py audit --plan examples/p107/session.json \
  --sent-wire /tmp/a0_commands.bin --capture /tmp/a0_capture.bin
python3 -m unittest discover -s tests -p 'test_p107_*.py' -q
```

## Explicit non-goals and attack limits

P107 does not add PCIe, DMA, host OS drivers, device enumeration, a command uploader, or shader compilation. Synthetic captures are test fixtures, **never** claims of physical execution. The protocol has no session nonce, digital signature or authenticated channel; a crafted/replayed set of valid packets can pass this format/content check. Image CRC32 is an error-detection checksum, not a cryptographic proof or complete pixel-by-pixel attestation. It cannot establish provenance or eliminate CRC32 collisions. Hardware frame telemetry can drop under backpressure; the strict audit intentionally fails if delivery is not complete. RTL sim is separately pending for P37/P45–P106.
