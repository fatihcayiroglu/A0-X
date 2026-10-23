# A0 PROD-SEAM-P10 — Backend Read Anti-ABA Incarnation Contract

## Scope

PROD-SEAM-P10 closes the bounded incarnation ambiguity left after P9. P9 tracks
one exact live base backend tag and line address and rejects duplicate or
unsolicited responses while that transaction is live. After completion,
however, the same base tag may be reused. A sufficiently late duplicate from an
older transaction could then alias a new transaction if the line address is also
reused. P10 adds an explicit finite read generation to the external backend
identity so that old and current incarnations are distinguishable.

The production successor is `a0_production_store_backend_epoch_seam`. The new
bounded primitive is `a0_backend_read_epoch_guard`. P9 and all earlier seams are
frozen predecessors.

## External incarnation identity

Every externally accepted read command carries
`{read_generation, P9_base_read_tag}`. The base tag remains the exact P9 identity
that already encodes line-port/slice plus network tag. P10 never reconstructs
that base identity from address or payload.

A global generation counter advances once for every externally accepted read.
P10 tracks the full generation, base tag, and line address for each read that has
not received an exact completion. A returned response is exposed to P9 only if
its external incarnation ID matches either a live P10 entry or a legal
same-cycle newly accepted read. A response with an old generation is suppressed
and raises the combined protocol diagnostic even when its base tag and line
address equal a newer live transaction.

## Registered command probe and predecessor visibility

P10 uses a one-entry non-handshaking command probe between frozen P9 and the
external backend. This is required because directly deriving P9 `ready` from
P10 command fields recreates a strict-lint `UNOPTFLAT` ready/valid loop through
P9's monolithic combinational guard.

The probe does not acknowledge P9 when it captures a command. P9 sees `ready`
only on the cycle that the exact probed command is accepted by the external
backend. Therefore P8/P9 store visibility semantics are not moved earlier and
the predecessor command must remain stable until real external acceptance.

## Generation wrap and safe reuse

The generation space is finite by construction. Silent wrap is forbidden.
When the maximum generation is allocated, P10 resets the next-generation value
to zero but asserts `epoch_wrap_block_o`; all subsequent reads are held before
external issue. Writes remain outside the read-generation credit mechanism.

Generation zero can be reused only after the external backend asserts
`backend_epoch_reuse_safe_i`. That signal is a strong flush/quiescence contract:
it promises that no response from a pre-wrap incarnation can subsequently
arrive. P10 requires its own live-read set to be empty when the signal is
asserted and fails stop if reuse-safe is claimed while a P10 read is live or a
new read is being accepted. This explicit handshake makes finite generation
wrap bounded instead of silently accepting an ABA risk.

## Response and fault contract

A current-generation response with an exact line address completes the P10
entry and is forwarded to frozen P9. A current-generation response with a wrong
line address is forwarded without freeing the P10 entry so that P9's existing
address-mismatch diagnostic remains authoritative; a later exact response can
still complete the transaction.

A stale/unknown generation, an already-completed incarnation, or an otherwise
non-live external read ID is suppressed before P9 and raises the P10 protocol
diagnostic. Backend fault provenance remains independent: an exact current
incarnation may carry a genuine backend fault and P9 receives that fault on the
correct restored base identity.

## Directed proof

The directed P10 test reuses the same P9 base tag and same line address across
two generations, injects a late response from the first generation while the
second is live, and proves it cannot become a refill. It then proves exact
current-generation completion.

With a two-bit test generation, the test deliberately reaches wrap, keeps two
reads live, completes them out of order, and checks base identity and fault
provenance. A new read is held while wrap is blocked. An old response during the
blocked period is rejected. Only after all live reads drain and the explicit
reuse-safe handshake occurs may generation zero issue again. The test also
replays a current-generation line-address mismatch to prove P9's integrity
contract survives P10 unchanged, then rejects a duplicate completed incarnation.

## Bounded scope

P10 is an anti-ABA read-identity milestone. It does **not** add dirty/writeback
coherence, ownership/snoops, atomics, global memory ordering, write-completion
acknowledgements, ECC/RAS recovery, DRAM scheduling, or physical VRAM
controllers/partitions. Those remain later bounded milestones.
