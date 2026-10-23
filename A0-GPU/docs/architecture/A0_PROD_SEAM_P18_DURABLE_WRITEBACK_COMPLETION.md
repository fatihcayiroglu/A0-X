# PROD-SEAM-P18 — durable dirty-victim writeback completion

P18 composes the frozen P17 dirty/writeback slice with an exact-attempt completion guard. P17's `wb_ready` is no longer tied to backend command acceptance: it is asserted only for a matching backend writeback **SUCCESS** status while the captured victim payload is still identical.

A retryable failure reissues the same line and full victim data with a new bounded retry incarnation. A non-retryable failure, or retry exhaustion, enters fail-closed state: P17 never sees writeback ready, the dirty victim is retained, and the blocked refill cannot escape. Stale/unknown statuses are diagnosed and cannot release the victim. No synthetic clean transition is permitted.

P18 does not yet define recovery from terminal writeback failure, multi-victim queues, writeback/read arbitration across slices, ownership/snoop coherence, or VRAM-controller durability. Those remain later bounded milestones.
