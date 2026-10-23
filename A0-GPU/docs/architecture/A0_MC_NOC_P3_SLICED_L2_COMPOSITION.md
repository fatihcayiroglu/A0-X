# A0 MC-NOC-P3 isolated multi-cluster sliced-L2 composition

## Status and bounded scope

MC-NOC-P3 is the first isolated end-to-end composition of the closed logical
multi-cluster transport and the closed V12 L2 primitive. It adds one structural
wrapper without modifying P0, P1, P2, V12, or production RTL:

```text
one post-local-fabric stream per cluster
        -> one unchanged P0 endpoint per cluster
           (`a0_cluster_line_noc_endpoint`)
        -> one unchanged P2 transaction router
           (`a0_mc_noc_logical_transaction_router`)
             (including the unchanged P1 request router)
        -> one registered elastic request seam per home slice
        -> one unchanged a0_l2_line_cache per home slice
        -> one independent line backend per slice

backend/L2 no-ready responses
        -> P2 reserved-owner capture and per-cluster service
        -> the originating P0 response endpoint
        -> one proper ready/valid local response stream per cluster
```

The wrapper is `a0_mc_noc_sliced_l2_subsystem`. Its only new runtime state is a
one-entry registered request hold per slice. The no-bypass holds break the
P2-valid/L2-ready combinational dependency exposed by direct composition while
retaining bubble-free same-edge dequeue/replacement. All other runtime state
remains in the closed components.

P3 remains load-line-only. It does not expose or transport stores, add
cross-cluster coherence, connect the production CU cluster, define a physical
NoC, or add a memory-controller policy.

## Why the V12 subsystem wrapper is not reused

`a0_multi_slice_l2_subsystem` contains `a0_line_slice_fabric`, which already
performs client arbitration, tag ownership, response capture, and response
selection. P2 now owns those transport functions for network tags. Nesting the
V12 fabric below P2 would duplicate ownership and arbitration and would convert
back to V12's no-ready client response contract.

P3 therefore reuses only the closed `a0_l2_line_cache` primitive, instantiated
once per physical slice. The complete line address and opaque network tag cross
one registered no-bypass seam between P2 and each L2. No tag repacking, address
truncation, or second home calculation is inserted in the wrapper.

## Parameters and identity widths

Primary parameters are:

```text
CLUSTER_COUNT=2
CUS_PER_CLUSTER=2
MSHR_COUNT=2
LINE_WORDS=8
L2_SLICE_COUNT=4
L2_SET_COUNT_PER_SLICE=256
L2_MISS_COUNT_PER_SLICE=16
SLICE_HASH_SHIFT=clog2(L2_SET_COUNT_PER_SLICE)
```

`SLICE_HASH_SHIFT` remains explicitly overridable. Its default matches the V12
sliced-L2 foundation. Derived widths are shared unchanged across P0, P2, and
the L2 instances:

```text
WORD_SELECT_W       = LINE_WORDS <= 1 ? 0 : clog2(LINE_WORDS)
LINE_ADDR_W         = 32 - WORD_SELECT_W
CLUSTER_ID_W        = CLUSTER_COUNT <= 1 ? 1 : clog2(CLUSTER_COUNT)
CU_ID_W             = CUS_PER_CLUSTER <= 1 ? 1 : clog2(CUS_PER_CLUSTER)
LOCAL_TAG_W         = MSHR_COUNT <= 1 ? 1 : clog2(MSHR_COUNT)
CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W
NETWORK_TAG_W       = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
SLICE_ID_W          = L2_SLICE_COUNT <= 1 ? 1 : clog2(L2_SLICE_COUNT)

CLUSTER_MAX_OUTSTANDING = CUS_PER_CLUSTER * MSHR_COUNT
OWNER_SLOT_W = max(1, clog2(CLUSTER_MAX_OUTSTANDING))
```

The frozen identity codecs remain:

```text
cluster-local tag = {cu_id, local_tag}
network tag       = {cluster_id, cu_id, local_tag}
```

The local-tag field is opaque over its complete encoded width. P3 does not add
an `MSHR_COUNT` range check for that field when the count is not a power of two.
P0/P2 continue to reject invalid cluster or CU encodings.

## Fail-closed configuration guards

The wrapper checks, before useful traffic:

- `CLUSTER_COUNT >= 1`;
- `1 <= CUS_PER_CLUSTER <= 4`;
- `MSHR_COUNT >= 1`;
- positive power-of-two `LINE_WORDS`;
- positive power-of-two `L2_SLICE_COUNT`;
- positive power-of-two `L2_SET_COUNT_PER_SLICE`;
- `L2_MISS_COUNT_PER_SLICE >= 1`;
- non-negative `SLICE_HASH_SHIFT`, below `LINE_ADDR_W` when more than one
  slice exists;
- an L2 set count that leaves at least one physical tag bit; and
- exact values for every exposed derived width and P2 owner-capacity parameter.

The P0, P1, P2, and L2 guards remain active behind these wrapper-level checks.
There is deliberately no constraint requiring a slice miss count to equal or
exceed aggregate cluster ownership. A full L2 miss table applies normal request
backpressure; it is a performance limit, not a configuration error.

## Cluster-local interfaces

There is one P0-compatible request stream per physical cluster:

```text
cluster_local_req_valid_i
cluster_local_req_ready_o
cluster_local_req_tag_i
cluster_local_req_line_addr_i
cluster_local_req_tag_error_o
```

The tag is `{cu_id, local_tag}`. Array index is the physical cluster. P0 adds the
constant generate-time cluster index and registers the network request before
presenting it to P2.

There is one proper ready/valid response stream per cluster:

```text
cluster_local_resp_valid_o
cluster_local_resp_ready_i
cluster_local_resp_tag_o
cluster_local_resp_line_addr_o
cluster_local_resp_fault_o
cluster_local_resp_data_o
```

P0 validates the returned network identity, strips only the cluster prefix,
and holds every response bit stable until the local ready/valid handshake. The
wrapper does not adapt this interface to the legacy no-ready production fabric.

## Request flow

1. A local request handshakes into its cluster's P0 request hold.
2. The P0 hold presents `{cluster_id, cu_id, local_tag}` and the exact line to
   the corresponding physical P2 ingress.
3. On the P0-to-P2 handshake, P2 reserves a cluster owner and P1 accepts the
   request into the selected slice's registered request hold.
4. P1 uses the unchanged address-only home function:

   ```text
   home = low_slice_bits(line_addr)
        XOR slice_bits(line_addr >> SLICE_HASH_SHIFT)
   ```

5. The physical P2 slice request handshakes into that slice's P3 elastic hold.
   P2 moves the owner from `QUEUED` to `AWAITING` at this acceptance boundary.
   The registered tag and line then remain stable until the L2 accepts them.
6. An accepted L2 miss handshakes with the same-index backend and occupies one
   L2 miss tracker; an accepted L2 hit occupies the closed one-entry
   hit-response buffer.

Different clusters targeting different homes can enter different P1 holds and
different L2 slices concurrently. Same-home requests retain P1's per-slice
round-robin arbitration and one-request-per-cycle service.

## Per-slice L2 and backend contract

Every physical slice instantiates one unchanged `a0_l2_line_cache` with:

```text
STORE_LANES = 1
SET_COUNT   = L2_SET_COUNT_PER_SLICE
GLOBAL_TAG_W = NETWORK_TAG_W
MISS_COUNT  = L2_MISS_COUNT_PER_SLICE
```

The mandatory store inputs are explicitly tied to zero. This is a scope fence,
not a coherence implementation.

Each L2 exposes one independent backend request lane:

```text
line_mem_req_valid_o
line_mem_req_ready_i
line_mem_req_network_tag_o
line_mem_req_line_addr_o
```

and one independent no-ready backend response lane:

```text
line_mem_resp_valid_i
line_mem_resp_network_tag_i
line_mem_resp_line_addr_i
line_mem_resp_fault_i
line_mem_resp_data_i
```

The backend tag width is `NETWORK_TAG_W`; despite the L2 primitive's internal
`global_tag` port name, the bits remain the exact network tag. Responses may
return out of order and several different slices may respond on the same edge.
Each response must return on the physical slice that issued its request and
must preserve the exact tag and line. There is intentionally no response-ready
signal and no response mux in P3.

The closed L2 permits a matching backend completion on the same edge as its
request handshake. The request has already crossed the P2-to-P3 seam, so its
P2 owner is `AWAITING` and accepts that immediate L2/backend response. Backend
responses have priority over a buffered L2 hit response; the hit stays buffered
until a backend-response-free cycle.

## Response flow and losslessness

Each L2 response wires directly to the same-index P2 response lane. P2 checks
the encoded cluster/CU, exact live owner, lifecycle, expected line, recorded
home, and freshly recomputed home. A correct response captures into its already
reserved owner without ready/backpressure. Thus all correct simultaneous slice
responses can be captured, including multiple replies for one cluster.

P2 services completed owners with one independent round-robin selector per
cluster. Its output remains locked while the destination endpoint is stalled.
The corresponding P0 endpoint accepts the full network-tagged response into its
registered response hold; that P2 handshake is the sole owner-retirement event.
P0 then restores `{cu_id, local_tag}` and waits for the cluster-local response
handshake.

No response ordering is implied by request order. Requests preserve P1's
per-slice accept order, while responses may complete out of order and become
visible to a cluster in P2 completed-owner service order. Different clusters
have no imposed response ordering.

## Runtime state and conservation boundary

The complete composition state is:

- one request hold and one response hold in each P0 endpoint;
- one request hold and one request RR cursor per slice inside P1;
- one P3 no-bypass elastic request hold per slice between P2 and the L2;
- `CUS_PER_CLUSTER * MSHR_COUNT` associative P2 owners per cluster, plus one
  locked response selection and response-service cursor per cluster; and
- direct-mapped cache state, `L2_MISS_COUNT_PER_SLICE` miss trackers, and one
  hit-response buffer in each L2 slice.

P2 ownership remains the transport/provenance guard; the originating CU MSHR
remains the semantic transaction owner. A tag cannot be reused while its P2
owner is queued, awaiting, complete, or emitting. The P2 owner retires as soon
as P0 accepts the network response into its registered response hold. After
that handshake, cluster-local backpressure retains only the P0 hold; P2 no
longer owns or rejects a new request with the same network tag.

The originating requester must therefore keep its local MSHR/tag live until the
`cluster_local_resp_valid_o && cluster_local_resp_ready_i` handshake and must
not reuse the tag merely because the response became visible. P3/P2 do not
enforce lifetime after network retirement. Scenario 30 proves same-cycle reuse
only at the disciplined local-response retirement boundary; it is not evidence
that early reuse while a P0 response is stalled is safe.

## Reset epoch

One shared reset, active-low `rst_n`, is connected unchanged to every endpoint,
P2/P1, and L2 slice. State reset is synchronously sampled on a rising clock
edge. Ready, valid, and error outputs are reset-gated by the closed transports,
and the L2 response path is reset-gated.

A sampled reset flushes endpoint holds, P1 holds/cursors, P2 owners/selections,
the P3 slice request holds, and all L2 valid/miss/hit state. Nothing is replayed
and no synthetic memory fault is generated.

The finite network tag contains no epoch bit. All P3 components and external
backends must therefore share the reset epoch, and a backend must guarantee
that no pre-reset response can appear after reset release. A stale response
whose tag and line exactly match a new transaction is otherwise physically
indistinguishable.

## Diagnostics

Four independent diagnostic vectors are public:

```text
cluster_local_req_tag_error_o  [CLUSTER_COUNT]
noc_req_tag_error_o            [CLUSTER_COUNT]
slice_resp_protocol_error_o    [L2_SLICE_COUNT]
noc_resp_tag_error_o           [CLUSTER_COUNT]
```

`cluster_local_req_tag_error_o` is P0's local invalid-CU check.
`noc_req_tag_error_o` is P2's physical-ingress identity check; it should remain
zero for traffic produced by a correctly wired P0 endpoint.
`slice_resp_protocol_error_o` reports malformed, orphan, premature, duplicate,
wrong-line, or wrong-home L2/backend responses without altering a valid owner.
`noc_resp_tag_error_o` is P0's network-response identity check; it should remain
zero for traffic emitted by a correctly wired P2 router.

The invariant diagnostics are not OR-reduced or converted into memory faults.
Keeping them distinct preserves the boundary that detected a composition bug.

## Store, refill, and coherence boundary

The closed L2 can invalidate a cached line and kill matching outstanding
refills when it observes a physical store. P3 intentionally supplies no such
events. Consequently P3 must not be used to claim coherent writable shared
memory, load-after-store visibility, or safe caching while another agent
mutates a cached line.

P3 validation uses load-line traffic and controlled backends. Cross-cluster
store ordering, targeted invalidation, acknowledgements, dirty ownership,
writeback, and directory state remain later milestones. The current
cluster-local store broadcast must not be extended into a global all-CU
broadcast as a shortcut.

## Source-grounded integration hazards

- The current production `a0_cu_cluster` public line-memory interface is below
  its internal shared L2, not the post-local-fabric P0 seam. P3 stays isolated;
  production refactoring remains a later milestone.
- The legacy `a0_line_request_fabric` response path has no ready signal. P3
  exposes P0's proper response ready input rather than silently tying it high.
- The complete line address must reach the L2 and backend. Removing home bits
  or re-indexing a line would change the closed L2 set/tag behavior.
- P2 already performs request routing and response ownership. Adding the V12
  line-slice fabric below it would double-route and double-own transactions.
- The backend response path is trusted no-ready traffic. The closed L2 forwards
  a presented backend response upstream; P2 supplies the visible provenance
  check, but an exact live tag/line cannot prove backend intent or an epoch.
- A direct P2-to-L2 connection forms a Verilator-visible and physically
  undesirable P2-valid/L2-ready dependency because P2 drives valid from an
  `always_comb` block that also consumes ready, while L2 ready consumes valid.
  The registered P3 seam breaks that cycle. Its full-slot turnover ready path
  still includes L2/backend readiness and remains P4 measurement input.
- Continuous backend responses can delay the existing one-entry L2 hit buffer
  because backend responses have priority. P3 does not alter this closed L2
  behavior.
- Two distinct network tags missing on one line can produce duplicate backend
  reads because the closed L2 does not merge same-line misses. This is legal
  and does not justify a P3 redesign.

## Verification contract

The black-box P3 test must use only public ports and prove at least:

- reset gating and flushing through endpoints, P2, and every L2;
- exact local-to-network-to-backend tag transformation and restoration;
- exact address, all-word data, and fault preservation;
- L2 miss, refill, later hit, and independent per-slice backend behavior;
- registered P3 seam latency, no combinational bypass, stall stability, and
  same-edge dequeue/replacement;
- two clusters with simultaneous misses to different homes, overlapping
  backend-valid responses, reverse completion order, and exact originating
  cluster/CU/local-tag delivery;
- same-home contention, different-home progress, backend request backpressure,
  and cluster-local response backpressure;
- simultaneous no-ready responses to one and different clusters without loss;
- duplicate-tag/capacity backpressure without false format error;
- malformed/orphan/wrong-line/wrong-home backend response fail-stop behavior;
- same-cycle backend completion supported by the closed L2 and P2;
- all four diagnostic boundaries; and
- final per-cluster, per-slice, and global conservation/drain.

Legal behavioral variants should include singleton, two-cluster/two-slice, and
non-power-of-two identity counts with power-of-two slices. A larger structural
lint should exercise materially larger cluster fan-in. Invalid primary counts,
slice/set powers of two, hash shift, and every overridable derived width must
fail closed.

The P3 gate must also run the closed P2, P1, P0, V12 sliced-L2, and production
recursive regressions using the frozen exact toolchain.

## Scalability debt and P4 boundary

P3 proves logical composition; it does not erase the closed scalability debt:

- one scalar request stream and response stream per cluster;
- `O(CLUSTER_COUNT * L2_SLICE_COUNT)` P1 request arbitration;
- linear P2 owner lookup and completed-owner scans;
- one request hold and one accepted request per cycle per slice;
- one cache access/response lane and one backend lane per slice;
- no VOQs, credits, virtual channels, multiple lanes, or physical links; and
- no same-line miss merging inside an L2 slice.

P4 must measure fan-in, ready depth, state growth, response bandwidth, and HOL
behavior before selecting queues, lanes, or physical topology. P3 does not
flatten clusters into a total-CU global fabric and introduces no
`O(total_CUs^2)` structure.

## Rollback boundary

P3 is exactly four new files relative to the closed V12/P0/P1/P2 foundations:
this document, one bounded composition RTL wrapper, one black-box testbench, and one
runner. Rollback consists only of omitting those files. No closed or production
file is modified by the isolated candidate.
