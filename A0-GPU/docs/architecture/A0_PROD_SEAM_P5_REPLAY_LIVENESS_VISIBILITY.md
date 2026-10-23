# A0-X PROD-SEAM-P5 — Replay liveness, finite backpressure, post-store visibility

## Scope

PROD-SEAM-P5 is the bounded successor to PROD-SEAM-P4.  P4 prevents a
store-invalidated backend completion from becoming an architectural successful
load and replays that request.  P5 makes that replay path finite, backpressured,
and starvation-resistant under repeated conflicts.

This milestone is **not** a full cache-coherence protocol.  It does not claim
ownership states, snoops, dirty state, writeback, atomics, a global memory
ordering model, or VRAM-controller coherence.

## Exact requester identity

Replay state is indexed by the existing cluster-local tag, which is the exact
concatenation of `{CU identity, local MSHR identity}`.  The cluster dimension is
kept separately.  Address or payload bits are never used to reconstruct the
requester.

For each cluster the replay table has `2**CLUSTER_LOCAL_TAG_W` encoded slots.
Only architecturally legal CU/MSHR encodings are issued by the production
frontend.  Once a replay slot owns a tag, a new external request carrying that
same tag is held not-ready until the replay reaches one architectural response
handshake.  This prevents state aliasing and tag reuse before retirement.

## Replay state machine

Each encoded requester slot is represented by three state bits plus the saved
line address:

- `valid=0`: no P5 replay ownership.
- `valid=1, wait_drop=1, inflight=0`: a stale P3 completion is being consumed
  internally and must not be exposed upstream.
- `valid=1, wait_drop=0, inflight=0`: replay is pending arbitration.
- `valid=1, wait_drop=0, inflight=1`: replay has been accepted by P3 and P5
  retains ownership until the final architectural response handshake.

If another conflicting physical store invalidates an in-flight replay, its
stale completion moves the same slot back through `wait_drop` and then to
pending.  The slot is not freed and the requester identity is not changed.
Therefore repeated store/refill races cannot create a second architectural
retirement for the same replay attempt.

## Round-robin liveness contract

Pending replay tags are selected by `a0_retry_round_robin_arbiter`.  Each
cluster owns a cursor.  The scan starts at the cursor, wraps across the finite
encoded tag space, and the cursor advances only after a replay request is
accepted by P3.

The bounded progress claim is conditional and explicit: after conflicting
stores quiesce, if P3/downstream request readiness eventually occurs, the
backend eventually returns the accepted request, and the upstream response
consumer eventually accepts a response, every continuously pending replay tag
will be selected after at most one scan of the other pending tags.  P5 does not
claim progress when the backend never responds, downstream ready remains false
forever, or conflicting stores never quiesce.

## Finite backend shadow capacity and backpressure

P5 keeps a shadow record for each P3/L2 backend miss that may later need stale
classification.  Capacity is exactly `L2_MISS_COUNT_PER_SLICE` entries per L2
slice.  A P3 backend request is visible at the public backend port only when a
shadow slot is free.  The same free-slot condition gates P3's backend-ready
input.  When all shadow entries are occupied, request backpressure propagates
into P3 instead of accepting a request and failing after the fact.

`PROD_SEAM_P5_TRACKER_OVERFLOW` remains as a fail-stop invariant: a legal
request handshake must never occur without a free shadow entry.

## Store/refill ordering and post-store visibility

P3 remains the authority for resident-line invalidation and L2 miss/refill
kill/install suppression.  P5 observes the same global physical-store stream
and classifies matching accepted backend transactions as stale.

A completion classified stale is consumed internally.  Its fault/data payload
is not forwarded as an architectural response.  The exact requester is replayed
and only the later non-stale completion can retire.

The visibility point of this bounded milestone is the physical-store
observation at the production store broadcast boundary.  After that observation
for a line:

1. an old resident matching L2 line cannot satisfy a later load as a valid hit;
2. an already outstanding or same-cycle conflicting pre-store refill cannot
   become the successful architectural load result; and
3. a replay/later load completes only through the post-invalidation path with
   backend data that is accepted as non-stale.

This does not itself write store data into the backend memory model.  Therefore
the producer of the physical-store observation and the backend memory system
remain responsible for making the actual store value visible according to the
larger memory-system contract.

## Fault provenance

Stale/retry state is private P5 metadata.  It is never encoded into the backend
fault bit.  A genuine fault returned by the fresh replay is forwarded unchanged
on the one architectural completion.  Thus invalidation ordering cannot be
mistaken for a backend access fault.

## Directed qualification

The P5 directed proof covers:

- round-robin rotation and wrap;
- same-tag request backpressure while replay owns that identity;
- repeated same-line store/refill invalidation across more than one replay;
- exact cluster/CU/local-MSHR identity preservation;
- no double architectural retirement;
- multiple clusters, tags, and L2 slices;
- a post-store access that must miss stale resident state and obtain fresh data;
- genuine backend fault provenance after replay; and
- legal reuse of the requester tag only after the final response handshake.

Canonical qualification also requires exact Verilator 5.050, strict-all lint,
parameter variants, the full P4 predecessor gate, zero outer/inner suppression
leak, and repository containment.
