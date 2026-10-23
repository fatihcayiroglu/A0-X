# PROD-SEAM-P20 — multi-slice writeback queue/arbitration foundation

P20 adds a bounded per-slice writeback queue and round-robin backend arbiter above the frozen P19 single-victim recovery contract. Each slice may have one queued command and one live backend attempt. The unified backend identity is `{slice_id, local_attempt_id}` so out-of-order status restores to the exact originating slice and attempt.

Backend backpressure cannot mutate a queued victim payload. Multiple slices may have live attempts concurrently, and one slice's failure status does not globally block other slices. A source cannot enqueue a second command while its prior command is queued or live. Same-cycle issue+status is explicitly supported without leaving a ghost active entry. Unknown, duplicate, or stale statuses are contained as protocol errors and are never routed to a source. Active state may only clear when `backend_status_valid_i` is asserted; local attempt ID zero is therefore not mistaken for an implicit status while the status bus is idle.

P20 is only the queue/arbitration foundation. Per-slice P19 durability/recovery remains the owner of when a dirty victim is actually acknowledged/cleaned. P20 does not yet instantiate a full multi-slice cache composition, global ownership/snoop coherence, writeback merging, or VRAM partition scheduling.
