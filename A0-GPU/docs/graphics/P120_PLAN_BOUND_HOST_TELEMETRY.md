# P120 — plan-bound host telemetry reconciliation

This milestone is **offline software evidence checking**, not hardware test evidence.

## Security model and limitations

- A `CompiledSession` from P107 supplies *independently configured* golden CRCs for each planned frame, and exact expected command tags.
- Caller supplies a separate binary `sent-wire` artifact. We byte-compare it with the compiled plan; this does **not** establish that the bytes actually reached a real device.
- Stream records are A0GR (16 B), A0GF (32 B) and A0GL (32 B), with packet CRC32 as in P118/P119. CRC32 detects accidental corruption; it does not authenticate origin.
- A0GR result packets must match all planned tags in order, have success status, and have no missing or extra results. The verifier does not claim **exactly once** hardware execution.
- A0GF telemetry for an accepted frame must have a sequence associated with its planned attempt index, independent expected CRC32, success status, expected good count, and zero bad/aborted counters.
- P119 verifies monotone counters, 16-bit wrapping of frame sequence, no duplicates/discontinuities, complete terminal snapshot accounting and required loss notices. A terminal snapshot is caller-supplied and is **not authenticated**.
- A0GL and terminal dropped count can account for lost telemetry, but **cannot prove the images corresponding to the missing frames**. Output status `PARTIAL_TELEMETRY_ONLY` means an incomplete visual evidence chain and CLI exit code **3**, never full pass.
- Output status `FULL_SOFTWARE_CONSISTENCY` with CLI exit code 0 means only *synthetic/input capture consistency*. It does not prove RTL simulation, FPGA execution, actual device reset, physical capture provenance, PCIe transactions, or displayed pixels.
- The epoch name is supplied by caller. Separate device reset/attestation evidence is not available.

## Resource bounds and failure model

- Maximum P107 plan: 128 frame goldens and 4096 expected command tags.
- Capture is fed in bounded <=64 KiB slices; parser buffers <=31 partial packet bytes; host results are checked incrementally, not collected in an unbounded list.
- First malformed packet poisons that audit instance permanently; no premature PASS. Check failures do not write a success report.
- Full source packet bytes still need to be provided to the CLI as a file and are read into memory; bounded *internal record state* does not mean bounded whole-process peak RSS. For arbitrarily huge captures, use the incremental Python API and file chunks.
- CLI refuses to overwrite any evidence input with its report.

## Usage

From `A0-GPU`:

```
python tools/a0_p120_plan_audit.py \
  --plan examples/p120/plan.json \
  --sent-wire examples/p120/sent_wire.bin \
  --capture examples/p120/synthetic_complete_capture.bin \
  --epoch synthetic-reset --final-dropped 0 \
  --output /tmp/a0_p120_full.json
```

Replace `--capture ...complete...` with `synthetic_one_lost_frame_capture.bin` and use `--final-dropped 1` to obtain **partial** outcome (exit 3). Example capture files were **synthetically encoded from software packet codecs**; none came from an FPGA.

## Real qualification blockers

1. Install `iverilog`/`vvp` or Verilator in a trusted build runner.
2. Run existing P103–P118 RTL testbenches and capture actual simulator logs (compile + exit + packet outputs).
3. Resolve any RTL mismatches; then replay *independently captured* output through P119/P120.
4. Prototype on FPGA, validate readback/CRC and full host telemetry under backpressure, reset and sustained loss.

Do not claim a hardware maturity increase solely from P120.
