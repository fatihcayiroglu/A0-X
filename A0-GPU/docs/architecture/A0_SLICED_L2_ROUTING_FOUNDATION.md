# A0 sliced-L2 routing foundation

## Status and scope

This milestone is an isolated scalability foundation after the committed
production multi-CU/shared-L2 cluster baseline at
`996d8c188e5d4f94b4bad5289392844d55d092f6`.

It does **not** replace production cluster wiring yet. It proves the next
memory-system topology in isolation:

```text
bounded requester clients
        |
        v
per-slice request arbitration
   |    |    |    |
   v    v    v    v
 L2-0 L2-1 L2-2 L2-3
   |    |    |    |
   v    v    v    v
backend / future memory-partition ports
```

The milestone intentionally does not add a physical mesh/ring NoC, cache
coherence, dirty ownership, writeback, translation, GDDR/HBM control, or a
multi-cluster production wrapper.

## Why slicing comes before multi-cluster production wiring

The current production cluster already has correct bounded cross-CU store
ordering and private-L1 invalidation observation. Extending that broadcast
mechanism across many clusters would create a non-scalable global fanout and
would still not constitute full cache coherence.

The next safe dependency is therefore to remove the single shared-L2 request
and backend bottleneck first, while keeping the proven production cluster
unchanged.

## Deterministic home-slice mapping

`L2_SLICE_COUNT` is restricted to a power of two in this foundation. The home
slice is selected from the full line address using a small XOR hash:

```text
slice = low_slice_bits(line_addr)
        XOR
        slice_bits(line_addr >> SLICE_HASH_SHIFT)
```

The subsystem defaults `SLICE_HASH_SHIFT` to
`clog2(L2_SET_COUNT_PER_SLICE)`. For four slices and 256 sets per slice this is
conceptually:

```text
slice[1:0] = line_addr[1:0] XOR line_addr[9:8]
```

The complete line address is still presented to each `a0_l2_line_cache`
instance. The existing L2 set/tag logic is therefore preserved unchanged.

Non-power-of-two slice counts are rejected fail-closed rather than silently
using biased or ambiguous routing.

## Request path

Each slice owns an independent round-robin arbiter and one-entry registered
request hold. A client can target only one slice for a given line request, but
clients targeting different slices can be accepted in the same cycle.

A held request remains stable until that slice asserts ready. Backpressure on
one slice does not consume the request slot of another slice.

Global tags remain the current requester shape:

```text
{client_id, local_tag}
```

The L2 treats this tag as opaque.

## Outstanding-tag ownership

A client/local-tag pair becomes busy when its request is accepted by the slice
fabric. The tag remains busy until the corresponding response is emitted back
to the client, including time spent queued inside the fabric.

This prevents a client from reusing a local tag while an older response for
that tag is still buffered.

The fabric tracks the expected line for every busy local tag. A slice response
is accepted only when all of the following hold:

- encoded client ID is valid;
- local tag is busy and still awaiting a slice response;
- no other slice has already claimed that tag in the same cycle;
- returned line matches the line registered for that tag;
- the returning slice is the deterministic home slice for that line.

Malformed responses are rejected without client fanout.

## Lossless no-ready response capture

The existing line-response contract has no ready signal. With multiple slices,
several responses may arrive in the same cycle, including several responses
for one client.

The slice fabric therefore owns `CLIENT_MAX_OUTSTANDING` response slots per
client. Response slots are an unordered pool rather than a FIFO: local tags
make the responses self-identifying, and the existing MSHR contract already
permits out-of-order completion.

The capacity invariant is:

```text
busy client transactions <= CLIENT_MAX_OUTSTANDING
completed-but-not-emitted responses <= busy client transactions
```

Therefore a protocol-correct set of simultaneous slice responses always has
space. `line_resp_overflow_o` is still provided as a fail-closed diagnostic if
that invariant is violated.

## Store observation routing

Private-L1 store observation remains a production-cluster concern and is not
changed here.

Inside the sliced-L2 subsystem, active physical store lanes are flattened only
for wiring compatibility with `a0_l2_line_cache`, then masked to exactly their
home slices using the same line-to-slice function as requests.

A scatter store may touch several slices in one cycle. Each affected slice
receives only its own lanes. Unrelated slices receive no store-valid event.

This avoids a future all-slice store broadcast while preserving the existing
L2 invalidation and refill-kill semantics.

## Banking is deliberately deferred

Slicing and banking are separate concerns:

- **slicing** replicates independent L2 instances and independent backend
  interfaces;
- **banking** adds parallel access structures inside one slice.

This milestone implements slicing only. Internal banking should be introduced
later if synthesis/performance evidence shows same-slice access bandwidth is a
material bottleneck.

## Memory-partition boundary

Every L2 slice exposes an independent existing line-memory backend interface.
That is the first clean future memory-partition boundary:

```text
L2 slice -> line backend -> future memory partition/controller
```

The foundation deliberately does not freeze a permanent 1:1 relationship
between an L2 slice and a physical DRAM channel.

## Multi-cluster/coherence boundary

This milestone does not permit a claim of coherent shared writable caching
across clusters.

A future scalable multi-cluster implementation must not turn the current
cluster-local private-L1 store broadcast into a global all-CU broadcast.
A likely future dependency is a home-slice/directory-style clean-sharer
protocol with targeted invalidation and acknowledgement before a physical
store is permitted to launch.

Conceptually:

```text
store queue head
    -> coherence acquire at home
    -> invalidate remote sharers
    -> collect acknowledgements
    -> store launch permit
    -> physical store
```

The current cluster-local pre-MSHR quarantine remains valuable and bounded;
it is not replaced by that future inter-cluster protocol.

## Long-term tag hierarchy

This milestone keeps:

```text
{client_id, local_tag}
```

A later cluster NoC endpoint may widen identity at the cluster boundary to an
opaque network transaction identity equivalent to:

```text
{cluster_id, client_id, local_tag}
```

CU-local modules do not need cluster identity embedded in them.

## Proof envelope

The targeted runner is intended to prove behavioral routing, response capture,
store routing, L2 miss/hit/refill behavior, and fail-closed guards. Static
elaboration variants cover bounded client counts, power-of-two slice counts,
and several outstanding capacities. The recursive gate then executes the
committed production multi-CU gate to prove historical compatibility.

The long-term A0-X topology remains hierarchical: bounded clusters, a physical
NoC replacing this logical routing abstraction, distributed L2 slices, and
multiple independent memory partitions. No structure introduced here requires
an O(total_CUs^2) global requester or store-broadcast fabric.
