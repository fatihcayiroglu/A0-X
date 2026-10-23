# A0 MC-NOC-P1 logical request routing

## Status and scope

MC-NOC-P1 is an isolated, topology-neutral logical request-routing milestone.
It consumes one post-endpoint line-read request stream per cluster and emits one
ready/valid request stream per address-derived home slice:

```text
cluster-local requester aggregation
        -> MC-NOC-P0 cluster endpoint
        -> one network-tagged request stream per cluster
        -> MC-NOC-P1 logical request router
        -> one request stream per home slice
```

P1 does not modify or connect to the current production hierarchy. The live
`a0_cu_cluster` still contains its shared L2 internally, and its public line
memory port is already downstream of that L2. Exposing a true production
post-local-fabric seam and proving single-cluster equivalence remain later
production-refactor work.

The milestone adds exactly four new files relative to the closed V12 and
MC-NOC-P0 foundations: this document, one RTL module, one black-box testbench,
and one Python runner. It does not modify either closed foundation.

## Source-grounded compatibility

The P0 endpoint freezes the request packet as ready/valid plus a line address
and the network tag:

```text
NETWORK_TAG = {cluster_id, cu_id, local_tag}
```

P1 accepts that packet shape unchanged. It neither strips nor repacks the tag;
the complete input tag is registered and delivered bit-for-bit to the selected
slice. There is no runtime cluster-ID sideband and no source-slice or home-slice
field in the packet.

The home calculation is the closed V12 address-only mapping:

```text
home = low_slice_bits(line_addr)
       XOR
       slice_bits(line_addr >> SLICE_HASH_SHIFT)
```

Cluster, CU, and transaction identity do not participate in this function.
Consequently, every cluster maps the same physical line to the same home slice.
`SLICE_COUNT` is restricted to a power of two, and an integration must use the
same `SLICE_HASH_SHIFT` as its downstream sliced-L2 subsystem.

## Parameters and widths

Primary parameters are:

```text
CLUSTER_COUNT
CUS_PER_CLUSTER
MSHR_COUNT
LINE_WORDS
SLICE_COUNT
SLICE_HASH_SHIFT
```

Derived widths match P0 exactly:

```text
WORD_SELECT_W       = LINE_WORDS <= 1 ? 0 : clog2(LINE_WORDS)
LINE_ADDR_W         = 32 - WORD_SELECT_W
CLUSTER_ID_W        = CLUSTER_COUNT <= 1 ? 1 : clog2(CLUSTER_COUNT)
CU_ID_W             = CUS_PER_CLUSTER <= 1 ? 1 : clog2(CUS_PER_CLUSTER)
LOCAL_TAG_W         = MSHR_COUNT <= 1 ? 1 : clog2(MSHR_COUNT)
CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W
NETWORK_TAG_W       = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
SLICE_ID_W          = SLICE_COUNT <= 1 ? 1 : clog2(SLICE_COUNT)
```

Legal configurations require a positive cluster count, `1..4` CUs per
cluster, at least one MSHR, positive power-of-two line words, positive
power-of-two slices, and a non-negative hash shift below `LINE_ADDR_W` whenever
more than one slice exists. Overridden derived widths must remain consistent.
Invalid configurations fail closed during startup.

## Request interfaces

The cluster side is an array of independent P0-compatible streams:

```text
cluster_req_valid_i
cluster_req_ready_o
cluster_req_network_tag_i
cluster_req_line_addr_i
cluster_req_tag_error_o
```

Array index is the physical ingress-cluster identity. The slice side is:

```text
slice_req_valid_o
slice_req_ready_i
slice_req_network_tag_o
slice_req_line_addr_o
```

Slice array index is the selected home. Output payload is driven only from
registered state; there is no combinational payload bypass.

## Identity validation and fail-closed behavior

For a presented valid input, P1 checks that:

```text
encoded cluster_id is legal
encoded cluster_id equals the physical ingress index
encoded cu_id is legal for CUS_PER_CLUSTER
```

A wrong legal cluster prefix, an unused cluster encoding, or an unused CU
encoding asserts only that ingress lane's `cluster_req_tag_error_o`. The lane
is not made ready, the malformed packet cannot enter a slice hold, and no
arbitration cursor or occupancy changes because of it. Legal traffic on other
lanes and destinations remains eligible to progress.

The local-tag field is opaque transport identity. P1 intentionally does not
decide whether the encoded MSHR exists, is live, is duplicate, or is already
outstanding. Those semantic ownership checks are not request-routing policy.

## Home routing, arbitration, and holds

Each slice owns an independent round-robin cursor and one registered elastic
request hold. A cluster request is eligible only at its one address-derived
home slice. Thus different slices may accept one request each on the same edge,
while same-slice contenders receive at most one grant.

A slice slot is available when its hold is empty or when the currently held
output will handshake on that edge:

```text
slot_available[s] = !hold_valid[s] || slice_req_ready_i[s]
```

The arbiter scans ingress clusters beginning at that slice's cursor. The cursor
advances only when the selected ingress completes the upstream arbitration
handshake:

```text
cluster_req_valid_i[g] && cluster_req_ready_o[g]
```

Merely presenting valid, observing an invalid packet, or toggling downstream
ready without an accepted ingress does not advance the cursor. If an existing
output handshakes while a replacement ingress is accepted, the new packet
replaces the retired hold on that edge. Enqueue wins over dequeue, allowing one
transfer per cycle after the initial registered latency.

While `slice_req_valid_o[s] && !slice_req_ready_i[s]`, that slice's valid, tag,
and line address remain stable. Its full hold prevents another request for the
same slice from being accepted, but it does not consume or block any other
slice's hold.

## Fairness contract

Round-robin progress is conditional on normal ready/valid liveness assumptions:

- the destination slice eventually accepts traffic;
- a waiting producer keeps valid and payload stable until accepted; and
- reset is not asserted during the progress interval.

Under continuous slice readiness and stable legal same-slice contention, every
cluster is accepted within at most `CLUSTER_COUNT` successful accepts at that
slice. This is a transfer bound, not an unconditional wall-clock-cycle bound
when the downstream slice is stalled.

## Reset, ordering, and conservation

`rst_n` is active-low and synchronously sampled. Valid, ready, and error outputs
are reset-gated. A reset edge clears every slice hold and RR cursor; held traffic
is flushed without replay or a synthetic memory fault.

P1 preserves the order in which each slice arbiter accepts requests. It does
not impose ordering between independent slices or couple request order to the
future response path. Within a reset epoch, every legal accepted input is
emitted exactly once unless reset flushes it. At final drain:

```text
total legal ingress accepts == total slice emissions
per-slice accepts == per-slice emissions
all slice holds empty
```

## Explicit non-goals and P2 boundary

P1 is load-line-request transport only. It adds no L2 storage, response router,
outstanding or busy table, expected-line tracking, duplicate/orphan detection,
response provenance validation, response buffering, stores, atomics, coherence,
directory, credits, virtual channels, physical mesh/ring, production adapter,
or memory-controller policy.

MC-NOC-P2 owns response routing and bounded response-side transaction ownership,
including cluster-prefix decode, exact CU/local-tag restoration, contention,
duplicate/orphan/malformed rejection, response provenance/home validation where
state exists, and same-cycle retire/reuse. CU MSHRs remain the final semantic
owners of transaction lifetime.

## Verification contract

The full behavioral configuration uses three clusters, three CUs per cluster,
three MSHR tag-width derivation, and four slices. It covers the four required
cluster/slice route combinations, same-line same-home routing across all
clusters, different-slice concurrency, same-slice bounded RR progress,
independent backpressure, held-payload stability, turnover, identity rejection,
reset flushing, and conservation.

The legal parameter matrix covers at least:

```text
K=1 U=1 M=1 S=1
K=2 U=2 M=2 S=2
K=3 U=3 M=3 S=4
K=4 U=4 M=4 S=4
```

Invalid `S=3` and out-of-range hash-shift configurations must fail before any
PASS marker. Exact Verilator 5.050 is used with `-Wall`, pin/width warnings as
errors, zero warning lines, and all generated products under `/tmp`.

The testbench is black-box: qualification depends only on public ports and
observable behavior, never private RTL identifier names.

## Scalability and architecture debt

P1 deliberately retains several measurable debts:

- the logical crossbar performs `O(CLUSTER_COUNT * SLICE_COUNT)` arbitration
  work and grows a combinational ready path with cluster fan-in;
- one scalar head stream per cluster can retain intra-cluster head-of-line
  blocking even though independent visible destinations progress;
- each slice has only one request-hold entry and one request-per-cycle service;
- the simple XOR mapping can hotspot for adversarial address patterns; and
- there are no VOQs, credits, multiple injection lanes, or physical links.

These limitations are inputs to MC-NOC-P4 measurement and later physical-NoC
selection. They do not alter the topology-neutral packet contract, and they do
not justify flattening the hierarchy into a `(clusters * CUs) -> slices` fabric.

## Rollback boundary

P1 is exactly four new files. Rollback consists only of omitting those files.
The seven V12 files, four P0 files, production RTL, index, and committed HEAD
remain unchanged until a separately qualified guarded live apply.
