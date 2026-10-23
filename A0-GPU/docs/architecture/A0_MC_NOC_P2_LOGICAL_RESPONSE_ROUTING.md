# A0 MC-NOC-P2 logical transaction and response routing

## Status and bounded scope

MC-NOC-P2 is an isolated, topology-neutral transaction-ownership and
response-routing milestone. It wraps the closed P1 request router without
modifying it:

```text
one P0 request stream per cluster
        -> P2 ownership reservation
        -> unchanged P1 address/home request routing
        -> one request stream per future L2 slice

no-ready slice responses
        -> P2 validation and reserved-owner capture
        -> per-cluster completed-owner round robin
        -> one ready/valid response stream per cluster
        -> unchanged P0 response endpoint
```

P2 does not connect this path to production, instantiate an L2, add stores or
coherence, or define a physical ring/mesh. P3 owns isolated multi-cluster
sliced-L2 composition. The production seam and single-cluster equivalence
remain later work.

The milestone adds exactly four files: this contract, one RTL wrapper, one
black-box testbench, and one Python runner. It does not modify closed
V12/P0/P1 files.

## Source-grounded compatibility

P0 freezes the network identity as:

```text
NETWORK_TAG = {cluster_id, cu_id, local_tag}
```

P1 accepts one stream per cluster, checks physical cluster/CU identity, applies
the V12 address-only home function, and holds one registered request per
slice. P2 instantiates that module unchanged and preserves every tag and line
bit across the wrapper.

The local-tag field remains opaque, exactly as P0/P1 specify. P2 does not
reject unused local-tag encodings when `MSHR_COUNT` is not a power of two.
Instead, it associates complete network tags with a bounded number of owner
slots. Invalid/unused cluster and CU encodings remain malformed.

V12 slice responses have no ready and may arrive simultaneously. A
single-response hold cannot safely consume that interface. P2 therefore
reserves storage at request acceptance and captures every protocol-correct
slice response directly into its unique reserved owner. There is no
response-overflow path for legal traffic.

## Parameters and fail-closed elaboration

Primary parameters are:

```text
CLUSTER_COUNT
CUS_PER_CLUSTER
MSHR_COUNT
LINE_WORDS
SLICE_COUNT
SLICE_HASH_SHIFT
```

Derived widths match P0/P1:

```text
WORD_SELECT_W       = LINE_WORDS <= 1 ? 0 : clog2(LINE_WORDS)
LINE_ADDR_W         = 32 - WORD_SELECT_W
CLUSTER_ID_W        = CLUSTER_COUNT <= 1 ? 1 : clog2(CLUSTER_COUNT)
CU_ID_W             = CUS_PER_CLUSTER <= 1 ? 1 : clog2(CUS_PER_CLUSTER)
LOCAL_TAG_W         = MSHR_COUNT <= 1 ? 1 : clog2(MSHR_COUNT)
CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W
NETWORK_TAG_W       = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
SLICE_ID_W          = SLICE_COUNT <= 1 ? 1 : clog2(SLICE_COUNT)

CLUSTER_MAX_OUTSTANDING = CUS_PER_CLUSTER * MSHR_COUNT
OWNER_SLOT_W = max(1, clog2(CLUSTER_MAX_OUTSTANDING))
```

Legal configurations require positive cluster/MSHR counts, `1..4` CUs per
cluster, positive power-of-two line words and slices, and a non-negative hash
shift below `LINE_ADDR_W` when more than one slice exists. All overridden
derived widths and owner capacity must be exact. Invalid configurations fail
during startup.

The implementation has `CLUSTER_MAX_OUTSTANDING` associative owner slots per
cluster. This matches the bounded aggregate capacity of the cluster's CU
MSHRs without interpreting opaque local-tag encodings.

## Unchanged home function

P2 and its internal P1 use the exact V12 address-only map:

```text
home = low_slice_bits(line_addr)
     XOR slice_bits(line_addr >> SLICE_HASH_SHIFT)
```

Cluster, CU, and local tag never affect home. The physical response input index
must equal both the recorded request home and a fresh calculation from the
returned line.

## Public request contract

The cluster side is P0 compatible:

```text
cluster_req_valid_i
cluster_req_ready_o
cluster_req_network_tag_i
cluster_req_line_addr_i
cluster_req_tag_error_o
```

The slice side is P1 compatible:

```text
slice_req_valid_o
slice_req_ready_i
slice_req_network_tag_o
slice_req_line_addr_o
```

A legal external request reserves an owner only on its
`cluster_req_valid_i && cluster_req_ready_o` handshake. The owner starts
`QUEUED` while the unchanged P1 hold contains the request. Its exact P1
slice-output handshake moves it to `AWAITING`.

Invalid cluster/CU identity asserts the physical ingress lane's tag error and
cannot handshake. A duplicate live tag or full owner table is legal
backpressure: ready stays low, tag error stays low, and ownership does not
change. Same-edge retirement makes its physical slot and exact tag available
for a replacement handshake.

## Ownership lifecycle and conservation

Each owner stores full network tag, expected line/home, state, fault, and all
response words:

```text
FREE -> QUEUED -> AWAITING -> COMPLETE -> EMITTING -> FREE
```

- `FREE -> QUEUED`: external cluster request handshake.
- `QUEUED -> AWAITING`: P1 slice request handshake.
- `QUEUED -> COMPLETE`: exact same-edge slice issue and response.
- `AWAITING -> COMPLETE`: matching slice response capture.
- `COMPLETE -> EMITTING`: per-cluster service selection.
- `EMITTING -> FREE`: cluster response handshake.

Owner identity is unique within a reset epoch. A tag remains owned while its
completion is queued or its output is stalled. The CU MSHR remains the
semantic load owner; P2's table is a transport/provenance guard.

Per cluster:

```text
accepted requests - emitted responses - reset flushes = non-FREE owners
QUEUED = accepted but not slice-issued
AWAITING = slice-issued but not response-captured
COMPLETE + EMITTING = captured but not emitted
non-FREE owners <= CLUSTER_MAX_OUTSTANDING
```

## No-ready response validation

There is one no-ready response input per slice:

```text
slice_resp_valid_i
slice_resp_network_tag_i
slice_resp_line_addr_i
slice_resp_fault_i
slice_resp_data_i
slice_resp_protocol_error_o
```

A response captures on its presentation edge only when:

- encoded cluster and CU are legal;
- an owner with the exact full tag exists;
- that owner is `AWAITING`, or is `QUEUED` while its exact request issues
  from the same physical slice on that edge;
- returned line equals the recorded expected line; and
- physical slice index equals recorded and recomputed home.

Malformed identity, orphan, premature response, duplicate in
`COMPLETE/EMITTING`, wrong line, and wrong physical/home slice assert only
that lane's protocol error. They do not alter ownership or create a synthetic
memory fault. Legal peers still capture on the same edge.

Because every legal response writes a different already-owned slot, all
simultaneous protocol-correct slice responses capture without arbitration or
backpressure, including several addressed to one cluster.

## Cluster response service and fairness

P2 exposes one proper ready/valid response stream per cluster:

```text
cluster_resp_valid_o
cluster_resp_ready_i
cluster_resp_network_tag_o
cluster_resp_line_addr_o
cluster_resp_fault_o
cluster_resp_data_o
```

The full network tag is preserved for P0 to validate and strip. A selected
owner is locked as `EMITTING`; valid, tag, line, fault, and every data word
remain stable throughout backpressure.

Each cluster owns an independent round-robin service cursor over its owner
slots. Selection scans completed owners from the cursor. The cursor advances
only when that cluster completes an output handshake. Same-edge retirement
and replacement selection is bubble-free after initial registered latency.
Different clusters can emit concurrently, and a stalled cluster cannot block
another.

Under a continuously ready destination, every continuously completed owner is
emitted within at most `CLUSTER_MAX_OUTSTANDING` successful service
opportunities for that cluster. This specifically closes V12's fixed
lowest-response-slot starvation debt for the new path. Allocation policy is
not part of the public fairness contract.

## Same-cycle issue, retirement, and reuse

The request-owner reservation precedes slice issue because P1 has registered
holds. A downstream slice is permitted to return a matching no-ready response
on the exact P1 request-handshake edge; P2 records it directly as
`COMPLETE`.

The cluster output handshake is the sole retirement event. If it occurs, a
new request with the same full tag may handshake that edge, including when the
table was full. The old payload is sampled from the retiring owner, while the
new tag/line/home metadata wins post-edge in the reused slot. Visibility or
capture of a response without an output handshake does not permit reuse.

A response for the newly reused identity cannot be accepted on that same
retirement edge because its request is only entering P1. Its earliest legal
response is its later P1 issue edge.

## Reset epoch and unavoidable ABA boundary

`rst_n` is synchronously sampled and gates valid, ready, and error outputs.
Reset flushes P1 holds, all owners, response selections, and RR cursors.

The finite frozen tag has no epoch/generation bit. A stale response whose tag
and line are bit-identical to a new transaction is therefore physically
indistinguishable. P2 does not claim impossible absolute ABA protection.
All connected endpoints, slices, and backends must share reset and guarantee
that a pre-reset response cannot reappear after reset release. A future
reset-domain milestone may widen the internal slice-side identity with a
generation field if that system guarantee cannot be maintained.

## Ordering

Requests retain P1's per-slice acceptance order; independent slices remain
unordered. Responses may complete out of order across owners and slices.
Each cluster's observable order is its completed-owner RR service order.
Different clusters have no imposed ordering. P2 adds no store/load ordering
or cache invalidation rule.

## Verification contract

The black-box testbench must prove:

- reset gating and flushing of queued, awaiting, completed, and emitting work;
- exact P1 home routing, registered hold, stall stability, and request payload;
- opaque unused local-tag transport;
- duplicate/capacity backpressure without false tag-format error;
- full-table same-cycle retirement and replacement;
- same-edge issue/response;
- exact response tag, line, fault, and all-word preservation;
- simultaneous responses to one and multiple clusters without loss;
- reverse-order completion and same suffixes in different clusters;
- registered cluster output and bit-stability under stall;
- per-cluster concurrency, RR wrap/sparse service, handshake-only cursor
  advancement, and the bounded adversarial-refill fairness case;
- malformed cluster/CU, orphan, premature, duplicate, wrong-line, and
  wrong-home rejection without phantom output or damage to the owner;
- final per-cluster and global conservation/drain.

Behavioral configurations include:

```text
K=1 U=1 M=1 S=1
K=2 U=2 M=2 S=2
K=3 U=3 M=3 S=4
K=4 U=4 M=4 S=4
```

`K=8 U=4 M=4 S=4` receives structural lint. Invalid slice count, hash
shift, zero primary counts, owner capacity, and derived widths fail closed.
Qualification uses exact Verilator 5.050, zero warning lines, literal ordered
markers, public-port-only tests, and build output under `/tmp`.

## Scalability debt and P3 boundary

P2 preserves cluster hierarchy. P1 request arbitration is
`O(CLUSTER_COUNT * SLICE_COUNT)`; response service is
`O(CLUSTER_COUNT * CLUSTER_MAX_OUTSTANDING)`; owner state is
`O(CLUSTER_COUNT * CUS_PER_CLUSTER * MSHR_COUNT)`.

Open debt is explicit:

- one response lane per cluster caps return bandwidth;
- owner-slot scans and request ownership lookup are linear;
- the request ready path includes capacity/tag lookup;
- P1 retains one scalar head stream per cluster and one hold per slice;
- no VOQs, credits, virtual channels, epoch bits, or physical links exist.

P4 must measure fan-in, ready depth, state growth, response bandwidth, and HOL
before adding multiple lanes or queues. P3 first composes this isolated router
with multiple P0 endpoints and independent L2 slices/backends, still
load-line-only.

## Rollback boundary

P2 is exactly four new files. Rollback consists only of omitting those files.
Closed V12/P0/P1 files, production RTL, committed HEAD, and index remain
unchanged until a separately qualified guarded live apply.
