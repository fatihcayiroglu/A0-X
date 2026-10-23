# A0 PROD-SEAM-P13 — Backend Write Status and Bounded Retry

## Explicit status and attempt identity

PROD-SEAM-P13 preserves the frozen P12 completion boundary and adds a successor
status/retry guard after it.  A P12 physical write ID is retained as the base
transaction identity.  Every external physical attempt additionally carries a
bounded retry incarnation, so the external attempt ID is
`{retry_incarnation, P12_write_id}`.  A status is actionable only when it
matches the exact currently-live attempt.  Status from an older retry attempt,
a duplicate status after completion, or an otherwise unknown attempt asserts a
protocol diagnostic and cannot release P12.

The status contract is explicit: SUCCESS is `success=1,retryable=0`;
retryable failure is `success=0,retryable=1`; terminal non-retryable failure is
`success=0,retryable=0`.  The illegal `success=1,retryable=1` encoding is a
protocol error and consumes no retry state.

## Exact-payload retry and fail-closed exhaustion

The first external write command is captured from P12 without changing P12 RTL.
A retryable failure preserves the captured word address, write data, line
address, and base P12 write ID exactly.  Only the retry incarnation advances.
The guard permits at most `MAX_RETRIES` retries after the initial attempt.
Therefore issue count is bounded to `1 + MAX_RETRIES` for one P12 write.

If the final permitted attempt also reports retryable failure,
`write_retry_exhausted_o` becomes sticky for that pending write.  No further
attempt is issued and no synthetic P12 ACK is generated.  A terminal
non-retryable status similarly asserts `write_terminal_failure_o` and stops the
transaction fail-closed.  Reset or a later system-level recovery milestone is
required to leave these terminal states; P13 never invents a successful store.

## Visibility release only on exact SUCCESS

P12 still withholds predecessor visibility after its write issue.  P13 feeds a
synthetic P12 completion ACK only for an exact SUCCESS status belonging to the
current external retry incarnation.  Retryable failure, terminal failure,
retry exhaustion, stale status, duplicate status, and malformed status cannot
raise that ACK.  Thus a conflicting refill cannot pass the frozen P8/P12
visibility fence until the backend has explicitly reported success for the
current attempt.

## Frozen predecessor preservation

P12 and every earlier production seam remain immutable.  P13 does not
reinterpret P10 read generation IDs or backend read fault provenance.  Reads
pass through the P13 command probe and are acknowledged upstream only on the
real external read issue handshake.  P12 write-ID wrap/reuse safety remains the
base-ID anti-ABA contract; P13 adds per-write retry incarnation to prevent a
late status from a previous attempt aliasing the current retry.

## Directed proof

The P13 directed test forces the first write attempt to return retryable failure
and proves no commit visibility.  It checks that the second attempt carries the
same P12 write ID, word address, and data but a different retry incarnation.  A
stale SUCCESS for the first attempt is rejected while a conflicting refill
remains held.  Exact SUCCESS for the retry updates the backing memory, releases
the store exactly once, and the held refill returns the new value.

The test then drives an initial attempt plus all permitted retries to failure,
proves there is no extra issue beyond the configured bound, and proves the
write remains fail-closed.  A late SUCCESS after exhaustion is rejected.  A
separate reset phase verifies terminal non-retryable failure also remains
fail-closed.  An independent faulting read finally proves predecessor read
identity and fault provenance are unchanged.

## Bounded scope

P13 is a bounded correctness milestone.  It supports one P12
completion-pending write at this boundary and a fixed retry limit.  It does not
add ECC/RAS policy, poison propagation, DRAM scheduling, dirty/writeback
coherence, ownership/snoops, atomics, global ordering, VRAM partitioning, or a
throughput-oriented write queue.  Recovery after retry exhaustion/terminal
failure remains an explicit later milestone.
