# A0 MC-NOC-P0 cluster line-NoC endpoint

## Status and scope

MC-NOC-P0 is an isolated, topology-neutral foundation for the future
multi-cluster sliced-L2 logical NoC.  It does not alter or connect to the
production hierarchy.  The endpoint models the seam after one cluster-local
`a0_line_request_fabric` and before any future multi-cluster router:

```text
cluster-local request fabric
        -> one post-fabric line-read stream
        -> a0_cluster_line_noc_endpoint
        -> future logical NoC
```

The `shared_client_req_*` and `shared_client_resp_*` signals inside
`a0_cu_cluster` are CU-wide pre-fabric arrays, not this stream.  The existing
`a0_cu_cluster.line_mem_*` interface is after L2 and is also not this seam.
P0 therefore remains isolated; exposing the post-local-fabric production seam
is P1 work.

P0 adds one endpoint RTL file, one black-box RTL testbench, one Python runner,
and this document.  It does not add a package.

## Non-goals

P0 does not implement L2, slice routing, a home-slice hash, multi-cluster
arbitration, stores, coherence, a directory, a physical ring or mesh, credits,
virtual channels, global busy/outstanding state, duplicate or orphan response
tracking, a legacy no-ready adapter, VOQs, multi-lane injection, or production
integration.  It makes no change to load/store ordering.

## Parameters and widths

The endpoint has these primary parameters:

```text
CLUSTER_COUNT=2
CLUSTER_ID=0
CUS_PER_CLUSTER=2
MSHR_COUNT=2
LINE_WORDS=8
```

`CLUSTER_ID` is an elaboration-time parameter only.  Derived parameters are:

```text
WORD_SELECT_W       = LINE_WORDS <= 1 ? 0 : clog2(LINE_WORDS)
LINE_ADDR_W         = 32 - WORD_SELECT_W
CLUSTER_ID_W        = CLUSTER_COUNT <= 1 ? 1 : clog2(CLUSTER_COUNT)
CU_ID_W             = CUS_PER_CLUSTER <= 1 ? 1 : clog2(CUS_PER_CLUSTER)
LOCAL_TAG_W         = MSHR_COUNT <= 1 ? 1 : clog2(MSHR_COUNT)
CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W
NETWORK_TAG_W       = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
```

Widths remain at least one bit for singleton counts.  Legal parameters require
`CLUSTER_COUNT >= 1`, `1 <= CUS_PER_CLUSTER <= 4`, `MSHR_COUNT >= 1`, a positive
power-of-two `LINE_WORDS`, and `0 <= CLUSTER_ID < CLUSTER_COUNT`.  Explicit
range checks reject unused encodings for non-power-of-two cluster and CU
counts.  The local-tag field is opaque; P0 deliberately does not decide whether
it denotes a currently live MSHR.

## Tag codec

```text
CLUSTER_LOCAL_TAG = {cu_id, local_tag}
NETWORK_TAG       = {cluster_id, cu_id, local_tag}
```

The request path prepends the endpoint's width-sized `CLUSTER_ID`.  The response
path accepts only its own legal destination cluster and a legal destination CU,
then strips the cluster field and restores `{cu_id, local_tag}` exactly.  There
is no opcode, source-slice field, home-slice field, or runtime cluster-ID port.

## Interfaces

The local request interface is ready/valid plus
`local_req_tag_i`, `local_req_line_addr_i`, and
`local_req_tag_error_o`.  The NoC request interface is ready/valid plus
`noc_req_network_tag_o` and `noc_req_line_addr_o`.

The NoC response interface is ready/valid plus
`noc_resp_network_tag_i`, `noc_resp_line_addr_i`, one-bit
`noc_resp_fault_i`, and `LINE_WORDS` 32-bit data words.  The local response
interface is ready/valid plus restored `local_resp_tag_o`, line address,
one-bit fault, and all data words.  P0 has a proper local response ready input;
the production legacy no-ready adaptation is deferred.

## Invalid identity behavior

When `local_req_valid_i` presents a tag whose CU encoding is outside
`CUS_PER_CLUSTER`, `local_req_tag_error_o` is asserted and
`local_req_ready_o` is deasserted.  The request is not captured, emitted, or
allowed to change state.

When `noc_resp_valid_i` presents a wrong destination cluster, an unused cluster
encoding, or an invalid CU encoding, `noc_resp_tag_error_o` is asserted and
`noc_resp_ready_o` is deasserted.  The response is not captured or delivered
and cannot create later phantom traffic.  A malformed transport identity is
never converted into a memory fault.  Legal routing in P1 must prevent a packet
for another cluster from being presented indefinitely to this fail-stop port.

## Buffering and ready/valid semantics

Request and response directions each contain one independent registered
elastic hold.  There is no combinational payload bypass.  Output valid and
payload come only from registered hold state and remain stable while valid is
asserted and ready is deasserted.

Conceptually:

```text
request slot available  = !request_hold_valid || noc_req_ready
response slot available = !response_hold_valid || local_resp_ready
```

Ready is reset-gated and additionally fail-closed for a currently presented
malformed valid input.  On a same-edge dequeue and replacement enqueue, the new
payload is registered and valid remains asserted.  Enqueue wins over dequeue,
so continuously ready legal traffic sustains one transfer per cycle without a
bubble after the initial registered latency.  Request and response holds have
no shared busy state and may handshake on the same edge.

## Reset, fault, ordering, and conservation

`rst_n` is active-low and synchronously sampled in `always_ff @(posedge clk)`.
While reset is asserted, valid, ready, and error outputs are gated low.  A reset
edge clears both occupancies and their payload registers.  Held traffic is
flushed without replay or synthetic fault; connected components must share the
reset epoch until a later epoch protocol exists.

A legal response preserves tag, line address, fault, and every data bit even
when fault is one.  The endpoint does not interpret cache-fill semantics.

Each direction preserves its own accepted order.  P0 does not impose global
completion order and does not couple request order to response order.  The
black-box scoreboard proves, per reset epoch:

```text
legal local request accepts - NoC request emits = request occupancy
legal addressed NoC responses - local responses = response occupancy
```

Each occupancy is zero or one, malformed attempts are excluded, and both are
zero at final drain.

## Verification contract

The main behavioral configuration is `CLUSTER_COUNT=3`,
`CUS_PER_CLUSTER=3`, `MSHR_COUNT=2`, and `CLUSTER_ID=1`.  Its ordered manifest
is:

```text
01 RESET_IDLE
02 LOCAL_REQUEST_ACCEPTED
03 REQUEST_CLUSTER_ID_ADDED
04 REQUEST_CU_LOCAL_TAG_PRESERVED
05 REQUEST_LINE_ADDR_PRESERVED
06 REQUEST_HOLD_CREATED
07 REQUEST_STALL_VALID_HELD
08 REQUEST_STALL_PAYLOAD_STABLE
09 REQUEST_EXACTLY_ONCE_DRAIN
10 REQUEST_BACK_TO_BACK
11 REQUEST_SAME_CYCLE_TURNOVER
12 REQUEST_CONSERVATION
13 ADDRESSED_RESPONSE_ACCEPTED
14 RESPONSE_CU_LOCAL_TAG_RESTORED
15 RESPONSE_LINE_ADDR_PRESERVED
16 RESPONSE_FAULT_PRESERVED
17 RESPONSE_LINE_DATA_PRESERVED
18 RESPONSE_HOLD_CREATED
19 RESPONSE_STALL_VALID_HELD
20 RESPONSE_STALL_PAYLOAD_STABLE
21 RESPONSE_EXACTLY_ONCE_DRAIN
22 RESPONSE_SAME_CYCLE_TURNOVER
23 WRONG_LEGAL_CLUSTER_NOT_ACCEPTED
24 WRONG_LEGAL_CLUSTER_NO_LOCAL_DELIVERY
25 UNUSED_CLUSTER_ENCODING_NOT_ACCEPTED
26 UNUSED_CU_ENCODING_NOT_ACCEPTED
27 INVALID_IDS_NO_LOCAL_DELIVERY
28 INVALID_LOCAL_REQUEST_CU_REJECTED
29 REQUEST_RESPONSE_INDEPENDENT_PROGRESS
30 SIMULTANEOUS_REQUEST_RESPONSE_HANDSHAKES
31 RESET_FLUSHES_HELD_REQUEST
32 RESET_FLUSHES_HELD_RESPONSE
33 SAME_LOCAL_TAG_DIFFERENT_CU_DISTINCT
34 SAME_CU_TAG_DIFFERENT_CLUSTER_DISTINCT
35 CODEC_ALL_LEGAL_AND_MAX_ROUND_TRIP
36 FINAL_CONSERVATION_AND_DRAIN
```

The runner requires all 36 literal TB markers exactly once and in this order.
It also compiles and runs behavioral smoke configurations:

```text
K=1 U=1 M=1 CLUSTER_ID=0 NETWORK_TAG_W=3
K=2 U=2 M=2 CLUSTER_ID=1 NETWORK_TAG_W=3
K=3 U=3 M=2 CLUSTER_ID=1 NETWORK_TAG_W=5 (full suite)
K=4 U=4 M=4 CLUSTER_ID=3 NETWORK_TAG_W=6
```

`K=3, CLUSTER_ID=3` must fail closed before any scenario marker.  Exact
Verilator 5.050 is used with `-Wall`, no warning suppressions, and temporary
build products under `/tmp`.

## P1/P2 compatibility and deferred work

P1 may connect this unchanged scalar packet contract to a logical router after
the production local request fabric, add routing/arbitration, and address timing
and head-of-line behavior.  Once a second synthesizable module needs the codec,
P1 may extract a shared package without changing the tag layout.

P2 owns bounded outstanding/busy state, duplicate/orphan and expected-line
checks, response provenance/home validation, and reset-epoch protection.  The
CU MSHR remains the final semantic owner of transaction lifetime.  Larger
buffers, credits, virtual channels, physical topology, multiple lanes, VOQs,
and high-bandwidth scaling remain later milestones.

## Rollback boundary

P0 is exactly four new files relative to the frozen V12 disposable baseline.
Rollback consists only of omitting those files; no production or V12 file is
modified.  No P0 live apply, commit, or push occurs during isolated candidate
qualification.
