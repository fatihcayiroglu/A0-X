# P109 — Independent offline capture binding (development only)

## Why P109 is necessary

`P108 verify_receipt` only checks internal bookkeeping. As designed, it can
accept a receipt claiming `CAPTURE_AUDITED_SOFTWARE_ONLY` without a corresponding
`capture_audit` record, or with `{ "status": "PASS" }` and no actual capture.
P109 must be used for decisions requiring a complete recorded host session.

## Inputs

1. **Plan**: P107 session JSON containing *independently supplied* golden frame CRCs.
2. **TX byte file**: the byte-for-byte purported host-written command stream.
3. **P108 receipt**: packet-boundary-aware forward-only accepted-byte journal,
   terminal state `CAPTURE_AUDITED_SOFTWARE_ONLY`.
4. **Capture byte file**: result and frame telemetry stream, NOT a receipt claim.

The checker recompiles the plan, compares the TX bytes, verifies the exact
P108 journal, recomputes the P107 capture audit over the supplied capture,
and compares the complete prior capture audit object to its recomputed result.
The P107 decoder checks packet CRC32, result tags, counts, frame CRC32, sequence,
and framing. A failed check MUST yield exit code 1. If successful, exit 0.

An `A0-P109-EVIDENCE-CONSISTENCY-v1` report includes SHA-256 of TX and capture
files and explicit `false` flags for physical hardware and reset proof.

## Epoch batches

`verify_epoch_batch` and CLI `batch` require unique caller-supplied epoch labels
across up to 128 entries. Reused labels fail the entire batch. This does NOT
prove that a reset physically happened. A caller can invent an epoch label or
regenerate an unauthenticated receipt. No exactly-once guarantee exists.

## Safety and scope

- The P108 receipts are unsigned. SHA-256 only detects change relative to an
  independently known digest, not malicious coordinated forgery.
- Captures in `examples/p109/` are SOFTWARE-GENERATED demonstration data.
- P109 does not communicate with a PCIe device/FPGA/ASIC and does not verify the
  physical provenance or authenticity of captures or reset acknowledgements.
- The sent-wire file is caller-provided; this is not bus-level proof of delivery.
- This contract validates P107 known frame CRCs but cannot establish whether
  those reference CRCs were computed correctly or measured independently.
- P109 adds Python code and CLI; **no RTL core was modified**.
- No real HDL simulator is available here: P106 real RTL gate exits `2 NOT RUN`.

## Example

From `A0-GPU` directory:

```sh
python tools/a0_p109_verify.py verify \
  --plan examples/p109/session_1.plan.json \
  --receipt examples/p109/session_1.receipt.json \
  --sent-wire examples/p109/session_1.wire.bin \
  --capture examples/p109/session_1.capture.bin

python tools/a0_p109_verify.py batch \
  --manifest examples/p109/batch.json
```

The CLI will not overwrite an input with `--report` and creates the report
exclusively. No automatic replay of uncertain writes is ever authorized.
