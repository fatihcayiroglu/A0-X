# P119 — strict epoch host-capture reconciliation

## Problem
P118 CRC validation and nondecreasing dropped counters alone cannot detect a reordered,
missing, or replayed A0GF frame if packet bytes/CRCs remain valid. P119 binds the wire's
16-bit attempted-frame sequence, cumulative drops, and the number of accepted frame
packets observed by the host **within an externally delimited reset epoch**.

## Invariant
For a captured **A0GF** packet with 16-bit `sequence` and cumulative `dropped`:
`sequence == (number_of_preceding_A0GF_packets + dropped) modulo 65536`.
This frame is then counted as one accepted frame.

For a captured **A0GL** loss notice, the same equality holds but the notice is not an
accepted frame. The A0GL `dropped` counter must strictly increase versus the preceding
A0GL and all telemetry counters must be monotone. A0GR result packets may interleave,
without affecting frame accounting. Their tag order may optionally be checked against
an externally supplied list. The decoder verifies each packet CRC and version.

At **finalization only**, the caller MUST provide both `final_attempted` and
`final_dropped` from an independently delimited epoch-end snapshot. P119 asserts:
`captured_A0GF_count + final_dropped == final_attempted`, the last telemetry record
witnessed the final drop count, and any nonzero final drop count has a terminal A0GL
notice of that total. Partial packets, unrecognized magic, counter regression, altered
sequence, packet duplication, packet removal, a saturated 32-bit loss counter, and
incompatible external final counters fail closed. The in-memory validator stays invalid
on the first parse error and cannot be reused.

A 16-bit sequence wraps; external full-width total attempted frames is necessary to
rule out silent skips of a whole 65536-event cycle. **Captures must start at reset**
(sequence and counters 0), be losslessly recorded, and end at an independently known
boundary. A human-provided epoch string does **not** prove a reset or provenance.

## Boundaries and limitations
This is a software stream auditor, **not a hardware authenticator**. CRC is not a
signature, and even perfect packet consistency does not imply the GPU rendered correct
pixels, ran on a device, or performed an actual reset. Caller-supplied final counters
are NOT cryptographically authenticated. Malicious packet fabrication remains possible.
If a device resets without an independently recorded boundary, reject/split the capture.
An overflow that saturates 0xffffffff drops is deliberately unsupported.

A0GF and A0GL remain byte-for-byte P118-compatible; this phase does not change RTL.
The CLI reads capture in 65536-byte pieces, each reduced to <=31 bytes of residual
buffer between chunks. Output reports are create-only; no existing file is overwritten.

## Usage (offline synthetic example)

```sh
cd A0-GPU
python tools/a0_p119_epoch_audit.py \
  --capture examples/p118/software_only_tail_loss.bin \
  --epoch independent-reset-sample \
  --final-attempted 6 --final-dropped 2 \
  --report /tmp/p119-audit.json
```

Exit `0` = software stream consistent with supplied snapshot; exit `1` = rejected.
There is no hardware-simulation pass in this result. To run the **independent** RTL
qualification gate, run `python tests/run_p118_host_loss_e2e.py` with Icarus installed.
If Icarus is absent, it returns **2 / NOT RUN**.
