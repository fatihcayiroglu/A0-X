# PROD-SEAM-P21 — multi-slice recoverable dirty/writeback composition

P21 composes multiple frozen P19 recoverable dirty/writeback slices through the frozen P20 round-robin writeback queue to one production-shape backend writeback boundary. P20 carries the backend identity as `{slice_id, local_attempt_id}` and restores every out-of-order status to exactly one P19 slice.

Durability ownership does not move into the queue. Each P19 slice retains its dirty victim and blocked replacement request until that exact slice observes a matching `SUCCESS`; queue capture or backend command acceptance never cleans a victim. Multiple dirty victims may therefore coexist across slices and multiple backend attempts may be live concurrently.

Terminal failure is isolated to the originating slice. Recovery-safe acknowledgement is explicit per slice: a failed slice may locally reset/rearm only its P18 guard after its own safe handshake while peer slices continue issuing, completing, and releasing independently. Recovery does not synthesize success, does not reset peer caches, and reissues the identical retained victim through the same P20 identity-preserving path. The per-slice recovery-safe handshake is the epoch boundary that makes reuse of a locally reset P18 attempt ID unambiguous.

P21 remains bounded. It does not add global ownership/snoop coherence, dirty sharing, writeback merging, VRAM partition scheduling, atomics, or a complete global memory-ordering protocol.
