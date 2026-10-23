# P118 — Telemetry loss notices (development contract)

## Confirmed predecessor gap

P117's four-entry A0GF FIFO snapshots `dropped_frame_events` when a frame is admitted. If the
last produced frame event is dropped after four records are already stored, no later A0GF
packet includes that drop count. A host that receives all queued records may falsely believe
nothing was lost. P118 adds a separate, **explicit loss record** without pretending that it
represents an actual completed frame.

## Wire protocol

P118 retains P48/P117 `A0GF` and P46 `A0GR` byte layouts unchanged. Loss notices use an
additional 32-byte CRC-protected **`A0GL`** record:

| Offset | Bytes | Description |
|---|---:|---|
| 0 | 4 | ASCII `A0GL` |
| 4 | 1 | Version: 1 |
| 5 | 1 | Notice kind: 1 (cumulative dropped-frame report) |
| 6 | 2 | Next attempted frame sequence, modulo 65536, little endian |
| 8 | 4 | Saturating cumulative dropped count, little endian |
| 12 | 4 | Snapshot of good-frame count |
| 16 | 4 | Snapshot of bad-frame count |
| 20 | 4 | Snapshot of aborted-frame count |
| 24 | 4 | Reserved: 0 |
| 28 | 4 | IEEE CRC32 over bytes 0–27, little endian |

`A0GL` is **not** a synthetic `A0GF` success/failure frame. It must not increment good or bad
frame counts. P49 continues to arbitrate 32-byte telemetry packets atomically; a legacy
P48/P49 host decoder which does not recognize `A0GL` fails closed intentionally. Use
`sim/a0_p118_loss_notice.py` `decode_p118_stream`, or upgrade your host before enabling P118.

## Producer logic and fairness

- FIFO carries whole immutable packets (real A0GF or A0GL).
- Every `frame_valid` increments the attempted sequence even when the frame is dropped.
- Overflow sets `notice_owed_q`; pending notice is never dependent on another `frame_valid`.
- The next free slot inserts an A0GL notice. On simultaneous free-slot and frame arrival,
  the pending loss notice has priority: the new frame is counted as a further loss.
- If that additional loss occurs concurrently with notice insertion, another notice is owed.
- A notice snapshots the previous edge's cumulative dropped count. Later loss is reported
  by a subsequent notice, avoiding false future-count promises.
- With permanently blocked `tx_ready`, no telemetry or loss notice can be delivered.
  Reset clears untransmitted diagnostics; no persistence across resets or power loss exists.
- The final notice cannot prove physical hardware provenance or guarantee end-to-end delivery.

## Auditing and limitations

`tools/a0_p118_loss_audit.py --capture <binary> --final-dropped <independent counter>`
parses A0GR/A0GF/A0GL, validates CRCs/fields and requires monotone witnessed drop counts.
Supplying a final count lets it refuse incomplete terminal loss reporting. The count is
externally supplied and **not authenticated**. Without a final count, silence after a dropped
last event cannot be independently detected from a truncated capture.

## Validation

- Software reference + failure injection: `python -m unittest discover -s tests -p 'test_p118_*.py' -v`.
- Real HDL: `python tests/run_p118_loss_fifo.py` and `python tests/run_p118_host_loss_e2e.py`.
- Exit codes: 0 = real Icarus HDL pass, 1 = compile/sim fail, 2 = tools unavailable / NOT RUN.
- Manual CI: `.github/workflows/a0-p118-loss-rtl.yml` (not executed in this environment).
- No FPGA, PCIe, external VRAM, physical pixel signal, production driver, or silicon evidence.
