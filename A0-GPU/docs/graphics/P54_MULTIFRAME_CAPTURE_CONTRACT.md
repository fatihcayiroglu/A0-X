# P54 Multi-frame Host Capture Acceptance (development-only)

## Purpose

P53 intentionally accepts **exactly one** frame. P54 adds a separate checker for 2–256 frame scripts that issue repeated `PRESENT` commands, without relaxing P53. It computes an independent expected BGR CRC32 for *each visible frame* from the existing P43/P44 **software reference** after each PRESENT. It then compares those expected values with an externally supplied A0GR/A0GF byte stream.

## Acceptance contract

- The JSON script follows P44 canonical validation and uses 1–256 uniquely tagged commands. The final command must be PRESENT and at least two PRESENT commands must be present.
- Commands succeed in the P43/P44 software reference; otherwise the script is unsuitable for this acceptance mode.
- Capture begins after device reset; frame sequence starts at 0 and increments by 1 without wrap (at most 256 frames).
- Every command produces one correctly ordered A0GR completion; every PRESENT produces one A0GF telemetry frame, in the same frame order.
- No frame is accepted **before** the associated PRESENT completion is received. Other command results may proceed before a pending frame arrives; a future tagged telemetry protocol would establish stronger pairing.
- Each observed A0GF frame must have the correct per-frame BGR CRC32, `good = frame_index + 1`, and zero `bad`, `aborted`, `dropped`, and `error`.
- Unknown bytes, invalid CRC, truncated frames, extra/missing command completions and extra/missing frame telemetry fail closed.
- The P49 host-stream parser provides reassembly; it cannot authenticate the physical origin of the data.

## Evidence limits

**Passing P54 means only that supplied bytes match a P43/P44 software model.** The helper `--make-synthetic-fixture` deliberately generates plausible bytes for tests and its output is not hardware or simulated RTL evidence. Cryptographic hash and CRC alone do not prove device origin; independently record simulator command lines, raw logs, source hashes or lab equipment captures before citing any hardware output. P54 is also not a complete graphics API, kernel driver, texture engine, or production GPU.

No assertions are made about performance, FPGA, ASIC, PCIe, or P37 canonical closure. The original P36 checkpoint remains separate.

## Usage

```sh
cd A0-GPU
python3 -m unittest discover -s tests -p 'test_p54_multiframe_attestation.py' -v
python3 tools/a0_p54_multiframe_attestation.py --script examples/p54_two_frames.json \
  --make-synthetic-fixture /tmp/a0-p54-software-only.bin
python3 tools/a0_p54_multiframe_attestation.py --script examples/p54_two_frames.json \
  --capture /tmp/a0-p54-software-only.bin --report /tmp/a0-p54-software-only-report.json
```

A genuine external capture must be collected **independently** and passed to `--capture`; the resulting report should be accompanied by that capture's separate provenance.
