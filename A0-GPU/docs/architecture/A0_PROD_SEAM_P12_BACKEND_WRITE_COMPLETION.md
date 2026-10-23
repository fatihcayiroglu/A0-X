# A0 PROD-SEAM-P12 — Backend Write Completion Visibility

## Scope

PROD-SEAM-P12 closes the bounded difference between backend write **issue** and
backend write **completion**.  P8-P11 intentionally used external command
acceptance as the abstract visibility point.  P12 adds a successor guard after
the frozen P11 command stream so a write can be issued to a more realistic
backend while predecessor visibility remains withheld until an exact completion
acknowledgement arrives.

The successor top is `a0_production_store_backend_completion_seam`; the bounded
primitive is `a0_backend_write_completion_guard`.  P11 and all earlier milestone
files remain frozen.

## Registered command probe and visibility preservation

P12 snapshots the P11 command into a one-entry non-handshaking probe.  Capturing
the command does not assert P11 ready.  A read is acknowledged upstream only on
its real external issue handshake.  A write is issued exactly once, but P11
ready remains low after issue while P12 retains the exact probed command and its
write incarnation ID.

Only the exact matching write-completion ACK raises predecessor ready.  Because
that ready propagates through the frozen P10/P9/P8 probes, the original P8 commit
visibility point is effectively delayed from external write issue to external
write completion without modifying any predecessor RTL.

## Write incarnation and anti-ABA wrap contract

Each externally issued write receives `next_write_id_o`.  With one bounded live
write, the issued ID is retained until its exact completion.  Unknown, wrong-ID,
duplicate, or stale ACKs assert the write protocol diagnostic and cannot release
the predecessor.

Write IDs are finite.  Issuing the maximum ID resets the next value to zero and
asserts `write_wrap_block_o`; a subsequent write may be snapshotted but cannot be
externally issued.  ID zero may be reused only after
`backend_write_reuse_safe_i`, which is a strong external quiescence promise that
no pre-wrap write ACK can still arrive.  Reuse-safe while a write is live is a
fail-stop contract violation.

## Read-path preservation

P12 does not reinterpret P10 read incarnation IDs.  Read commands preserve the
full P10 external read ID, line address, and payload fields through the P12 probe
and are acknowledged upstream on external read issue.  Backend read responses
continue directly into the frozen P11/P10 response path, retaining P9/P10
transaction integrity and backend fault provenance.

## Directed proof

The P12 directed test stalls the external issue boundary and proves write command
stability.  After issue, it proves the store commit still cannot complete.  A
wrong ACK is rejected.  A conflicting refill is accepted into the frozen line
request slot but cannot reach the external backend while the write completion is
pending.

The modeled backing memory is updated only on the exact write ACK.  That ACK then
releases the commit, after which the held refill issues and returns the newly
visible value.  A duplicate ACK is rejected.

With a two-bit write ID, the test consumes IDs 0,1,2,3, proves wrap backpressure,
rejects a stale ID-0 ACK during wrap, performs explicit reuse-safe release, and
then proves the new ID-0 write completes normally.  An independent faulting read
finally proves P10 read identity and fault provenance are unchanged.

## Bounded scope

P12 intentionally supports one completion-pending write command at this boundary.
It is a correctness milestone, not a throughput-optimal write queue.  It does not
add write faults/retry, ECC/RAS, DRAM scheduling, dirty/writeback coherence,
ownership/snoops, atomics, global ordering, or a physical VRAM controller.  Those
remain later bounded milestones.
