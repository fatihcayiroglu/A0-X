# P53 — strict single-shot host frame attestation

## False-success finding

P52 requires a known reset, exactly one final PRESENT, no other background
scanout, and a single quiescent capture. Its parser previously required **at
least one** A0GF packet; it did not reject multiple otherwise-valid frames.
Even a single frame with `good=5` could be accepted. The two cases were observed
to return `status=PASS` before this patch.

## Fixed fail-closed criteria

The supplied binary capture is checked by the original P52 decoder with its
CRC32, magic/version/flags, completion tag/order/status, discard/truncation,
frame pixel CRC, and sequence/counter-error checks. P53 adds:

1. Exactly **one** complete A0GF telemetry record (no duplicates, no extras).
2. That record must have cumulative `good==1` following the specified reset.

If the record is missing, the preexisting `no_complete_frame_telemetry` error
continues to fire; the new count mismatch error can also fire.

### Proof and limits

- Eight new regression tests include duplicate CRC-valid frame, forged counters,
  randomized chunking, malformed CRC, missing frame, and CLI nonzero returns.
- Red-phase results prove these checks were actually absent in the preceding
  P52 implementation, not merely tests that always passed.
- The test fixtures are software-synthesized and are NOT GPU captures.
- The accepted response is `PASS` only for supplied bytes matching the
  software reference and explicit single-shot assumptions. It does not verify
  source authenticity; CRC32 is not a cryptographic authentication mechanism.
- For continuously refreshed or reset-ambiguous systems, this one-shot gate
  must NOT be used as an unconditional functional-performance acceptance gate.
- P37 and P45–P51 HDL simulation, synthesis, FPGA and device measurements remain
  unverified by this change.
