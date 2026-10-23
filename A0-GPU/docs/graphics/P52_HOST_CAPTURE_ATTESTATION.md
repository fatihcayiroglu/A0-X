# P52 — One-PRESENT host capture acceptance contract

Status: **development; Python comparisons only; no RTL simulator here.**

## Why

P45–P51 created command and response paths and a per-frame CRC stream. A CRC-valid host capture by itself cannot prove that the requested triangle was drawn; the frame's pixel CRC also needs to be checked against a separately computed expected image, and command completion tags must be conserved.

## Contract and limitations

- The input JSON script is strictly parsed using P44 (`width`, `height`, and `commands`). P52 accepts up to 256 commands with **exactly one, final `PRESENT`**; this is a deliberately limited *single-shot* test fixture. It does not attempt to infer ordering under continuously running scanout, concurrent command streams, or reset.
- Reference graphics are produced by the P43/P44 **software** device, not RTL. P47 frame CRC is computed by CRC32 over each visible pixel in **B,G,R** order, matching the P47/P48 contract. The reference image SHA-256 records visible **R,G,B** order.
- A captured stream must contain **exactly one result for each requested command, in order**, and at least one full frame-telemetry packet after the final completion. Results arriving after telemetry are rejected under this single-shot contract.
- Every packet must pass CRC32/version/flags checks; parser resynchronization, dropped bytes, corrupt candidates, or truncated trailing bytes fail the verdict.
- Frame telemetry must have its `error` flag unset, no bad or aborted frames, at least one `good` frame and exact expected image CRC32. Frame sequence must begin at zero, show no observable gaps or ambiguities, and no telemetry-drop increments. These assumptions require the capture to start after a known device reset and with no preexisting in-flight traffic.
- The success verdict means **the supplied bytes match a software reference under the stated single-shot capture assumptions**. It does **NOT** authenticate that bytes came from hardware, and does not claim GPU silicon, FPGA correctness, graphics API conformance, performance, P37 closure, or P51 RTL completion.
- CRC32 is an error-detection mechanism, not an authenticity proof; accidental collisions are possible.

## Run a synthetic fixture (for checking the auditor, not device evidence)

```sh
cd A0-GPU
python3 tools/a0_p52_capture_attestation.py --script examples/p44_triangle.json \
  --make-software-fixture /tmp/p52-synthetic.bin \
  --report /tmp/p52-synthetic-source.json
python3 tools/a0_p52_capture_attestation.py --script examples/p44_triangle.json \
  --capture /tmp/p52-synthetic.bin \
  --report /tmp/p52-software-check.json
python3 -m unittest discover -s tests -p 'test_*.py' -q
```

To run this acceptance test against a future real simulator/FPGA capture, obtain the binary A0GR/A0GF stream from an external run with a verified provenance and a known single-shot reset/start policy. Invoke `--capture` with that path, keep the hardware run's tool/device logs separately, and never replace a real capture with a generated fixture. Exit 0 = capture compared successfully; 1 = mismatch; 2 = invalid usage/IO/reference script.
