# P55 independently implemented graphics software oracle

Status: **development only; no RTL/FPGA/ASIC closure**.

## What is compared

- The inherited P54 P43/P44-based software model produces per-`PRESENT` output (frame CRC32 and RGB SHA-256).
- A new, deliberately separate direct-renderer computes coverage at exact rational pixel centres with the y-down top-left rule, direct double-bank ownership, and RGB/BGR conversion without importing the rasterizer, display, command-execution, or CRC helper code of P38–P43.
- `a0_p55_dual_oracle.py` refuses to consider any supplied host byte capture until the independent frame hashes, CRCs, PRESENT tags and frame counts match. An observed capture is then processed using the unchanged P54 packet checker.

This covers more than comparing two CRC implementations: it rebuilds geometry and framebuffer state independently. Both software models still share P44 script parser and the documented rendering contract; agreement cannot establish HDL correctness, real device origin, or architectural independence in the strict formal sense.

## Regression against a false positive

The P55 unit test deliberately injects a wrong expected first-frame CRC into the inherited P54 reference and constructs a corresponding synthetic host byte stream. In that artificial example the inherited P54 checker returns PASS because the reference and fabricated bytes agree; the new P55 check rejects the pair because the independent renderer disagrees. This is a **test-injected model corruption**, not a demonstrated real defect in the P54 implementation.

Other tests include random multi-scene CLEAR/TRIANGLE/PRESENT workloads, bank reuse, reversed winding, degenerates, extreme clipping, CRC mutation, truncation, duplication, CLI failure status and evidence-level labels.

## Usage

```bash
cd A0-GPU
python3 -m unittest discover -s tests -p 'test_*.py' -q
python3 tools/a0_p55_dual_oracle.py --script examples/p54_two_frames.json \
  --report /tmp/p55-reference-only.json
# Only for an independently captured byte stream; attach separate origin evidence:
python3 tools/a0_p55_dual_oracle.py --script examples/p54_two_frames.json \
  --capture /path/to/external_capture.bin --report /tmp/p55-capture-check.json
python3 tests/run_p50_rtl_gate.py --receipt /tmp/p55-actual-rtl-gate.json
```

- Without `--capture`, only the two software models are compared; the receipt is `SOFTWARE_ONLY_NOT_RTL_OR_HARDWARE`.
- A PASS with `--capture` proves only that the **supplied bytes** agree with those models, not that they came from a real RTL simulator or hardware. A separate trust chain is required.
- Exit status 0 = model/byte check PASS; 1 = byte capture failed; 2 = rejected script, oracle disagreement or tooling error.
- `P37` canonical gate and inherited `P45–P51` actual RTL qualification remain open. Do not mark P55 CLOSED until genuine HDL gates and required inherited conditions have passed.
