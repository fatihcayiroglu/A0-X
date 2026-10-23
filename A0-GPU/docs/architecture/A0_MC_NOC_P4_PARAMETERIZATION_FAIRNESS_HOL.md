# A0 MC-NOC-P4 parameterization, fairness, and HOL measurement

## Status and boundary

MC-NOC-P4 is a measurement and behavioral-qualification milestone over the
unchanged MC-NOC-P3 subsystem. It adds no DUT RTL. The measured topology is:

```text
K scalar cluster streams
  -> K unchanged P0 endpoints
  -> one unchanged P2 transaction router containing unchanged P1
  -> S unchanged P3 registered request seams
  -> S unchanged sliced L2 caches
  -> S independent scalar line-memory backends
```

The P4 testbench instantiates `a0_mc_noc_sliced_l2_subsystem` and observes only
its public ports. Private P0, P1, P2, P3, and L2 identifiers are not a
qualification interface.

P4 does not infer that VOQs, deeper queues, multiple lanes, or a physical NoC
are required. Such an inference needs a breached target for frequency, area,
throughput, or maximum permitted HOL delay. No such quantitative target is
currently defined. Timing is therefore reported exactly as:

```text
MC_NOC_P4_TIMING=NOT_MEASURED
```

Verilator compile/lint proves elaboration, parameter legality, and warning
cleanliness. It is not synthesis or static timing analysis.

## Symbols and derived widths

The measurement equations use:

```text
K   = CLUSTER_COUNT
U   = CUS_PER_CLUSTER
M   = MSHR_COUNT
W   = LINE_WORDS
S   = L2_SLICE_COUNT
N   = L2_SET_COUNT_PER_SLICE
Q   = L2_MISS_COUNT_PER_SLICE
b(x) = max(1, ceil(log2(x)))

A    = 32 - log2(W)
CID  = b(K)
CUID = b(U)
LT   = b(M)
CLT  = CUID + LT
NT   = CID + CLT
SID  = b(S)
O    = U * M
OW   = b(O)
TAG  = A - log2(N)
```

Legal P4 configurations retain the closed-module requirements: `W`, `S`, and
`N` are powers of two; `1 <= U <= 4`; all primary counts are positive; the hash
shift and every overridable derived width equal their canonical expressions.

## Arbitration and lookup work

The source-level comparison/selection cardinalities are:

```text
P1 request arbitration        = S arbiters, K candidates each = K*S
P2 ingress duplicate/free     = K scans, O entries each       = K*O
P2 issue-owner lookup         = S scans, O entries each       = S*O
P2 response-owner lookup      = S scans, O entries each       = S*O
P2 same-cycle issue check     = S scans, S entries each       = S*S
P2 completed-owner selection  = K arbiters, O entries each    = K*O
L2 request miss/free lookup   = S scans, Q entries each       = S*Q
L2 response tracker lookup    = S scans, Q entries each       = S*Q
```

The P2 same-cycle response loop tests all `S` issue indices for each response
index even though equality admits only the matching index. Synthesis may
collapse that expression. P4 records `S*S` as source work and does not claim it
as post-synthesis cell count.

## Full-slot ready cone

P0, P1, and P3 each contain a one-entry registered, no-payload-bypass request
hold. Their full-slot turnover readiness remains combinational. For a miss at
the L2 head, the sensitized dependency is:

```text
line_mem_req_ready_i
  -> L2 request readiness (Q-entry free/tag decision merges here)
  -> P3 full seam turnover
  -> P2 issue qualification (O-entry owner decision merges here)
  -> P1 K-way slice arbitration
  -> P2 ingress readiness (O-entry capacity/tag decision merges here)
  -> P0 full request-hold turnover
  -> cluster_local_req_ready_o
```

An empty hold functionally terminates its downstream-ready dependency. Valid
and payload remain registered at all three boundaries. P4 proves the observable
same-cycle ready sensitivity and payload stability under stall, but labels the
physical path delay `NOT_MEASURED`.

## Registered-state equations

The declaration-level registered bits in the composed transport are:

```text
P0 = K * (3 + NT + CLT + 2*A + 32*W)

P1 = S * (CID + 1 + NT + A)

P2 = K*O * (4 + NT + A + SID + 32*W)
     + K * (1 + 2*OW)

P3 = S * (1 + NT + A)
```

The sliced-L2 declaration-level state is:

```text
L2 = S * [
       N * (1 + TAG + 32*W)
       + Q * (2 + NT + A)
       + (1 + NT + A + 32*W)
     ]
```

The terms respectively represent cache lines, miss metadata, and one hit
response hold per slice. Tool memory inference can change the physical
implementation without changing this architectural state count.

## Required configuration matrix

The architectural triplets in the roadmap mean `K clusters x U CUs x S
slices`. P4 names `M` explicitly and uses the following behavioral matrix:

| K | U | M | W | S | N | Q | Purpose |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 1 | 1 | 1 | 1 | 1 | 1 | singleton functional smoke |
| 2 | 2 | 2 | 4 | 2 | 4 | 2 | two-cluster/two-slice smoke |
| 3 | 3 | 3 | 4 | 4 | 8 | 4 | full P4 behavioral suite |
| 4 | 2 | 2 | 8 | 4 | 16 | 4 | asymmetric-CU functional smoke |
| 4 | 4 | 4 | 8 | 4 | 16 | 4 | maximum-current-CU functional smoke |

The compile/lint-only structural configuration is:

```text
K=64 U=4 M=4 W=8 S=64 N=256 Q=16
TOTAL_CUS=256
O=16 owner slots per cluster
TOTAL_OWNER_SLOTS=1024
CID=6 CUID=2 LT=2 CLT=4 NT=10 SID=6 OW=4 A=29
```

It intentionally creates 64 independent backend lanes and 64-way arbitration
at every slice. It does not instantiate 256 CUs; P3 begins after each cluster's
local fabric, so `U` sizes tags and ownership rather than duplicating CU RTL.

For `W=8`, `N=256`, and `Q=16`, the structural proxy table is:

| K/U/M/S | CUs | O | K*S | K*O | S*O | S*S | request S*Q | response S*Q | routing bits |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1/1/1/1 | 1 | 1 | 1 | 1 | 1 | 1 | 16 | 16 | 685 |
| 2/2/2/2 | 4 | 4 | 4 | 8 | 8 | 4 | 32 | 32 | 3,132 |
| 3/3/3/4 | 9 | 9 | 12 | 27 | 36 | 16 | 64 | 64 | 9,323 |
| 4/2/2/4 | 8 | 4 | 16 | 16 | 16 | 16 | 64 | 64 | 6,312 |
| 4/4/4/4 | 16 | 16 | 16 | 64 | 64 | 16 | 64 | 64 | 20,648 |
| 64/4/4/64 | 256 | 16 | 4,096 | 1,024 | 1,024 | 4,096 | 1,024 | 1,024 | 339,584 |

For the 256-CU structural point:

```text
ROUTING_REGISTERED_BITS=339584
ROUTING_REGISTERED_BYTES=42448
ROUTING_REGISTERED_KIB=41.453125
L2_REGISTERED_BITS=4615680
L2_REGISTERED_BYTES=576960
L2_REGISTERED_KIB=563.4375
COMBINED_REGISTERED_BITS=4955264
COMBINED_REGISTERED_BYTES=619408
COMBINED_REGISTERED_KIB=604.890625
```

## Bandwidth bounds

The unchanged scalar interfaces impose hard architectural ceilings:

```text
cluster request injection              <= K lines/cycle
slice request acceptance               <= S lines/cycle
steady-state new-request rate          <= min(K,S) lines/cycle
simultaneous P2 response capture       <= S lines/cycle
instantaneous completed-owner drain    <= K lines/cycle
steady-state response rate             <= min(K,S) lines/cycle
steady-state response payload          <= 32*W*min(K,S) bits/cycle
per-cluster request or response rate   <= 1 line/cycle
per-slice request/response/backend rate<= 1 line/cycle
```

P2 can drain previously completed owners at `K` lines/cycle for a bounded
interval even when `K > S`; continuing traffic is still supplied by at most `S`
slice responses per cycle.

## Finite response storage

Full-line payload register positions outside the cache arrays are:

```text
P2 owner payloads = K*O
P0 response holds = K
L2 hit holds      = S
TOTAL             = K*O + K + S lines
```

For one stalled cluster, the P2/P0 response boundary can physically retain `O`
completed owner payloads plus one P0-held response, or `O+1` completed lines.
This is a boundary-scoped storage statement, not permission to reuse a local
tag early. The requester must retain a tag until its local response handshake.
The public P0 request hold can additionally contain one request that has not
yet obtained a P2 owner; it is not response capacity.

The full behavioral configuration has `O=9` but twelve valid opaque local-tag
encodings because `U=3` and `LT=2`. Its `O+1` experiment uses ten distinct
network tags, including legal unused local-MSHR encodings, without early reuse.

## Fairness semantics

P1 stores one RR cursor per slice. With a continuously available downstream
slice and continuously eligible contenders, a cluster is served within at most
`K` accepted service opportunities. The full test keeps every cluster's public
request source valid, refills winners with three distinct same-home tags, and
checks the reset-origin prefix plus every rolling window of `K` successful
backend handshakes. A deliberate two-cycle backend-ready-low gap must preserve
the held payload and count as zero opportunities. The bound is not `K`
wall-clock cycles, because downstream stalls create no service opportunity.

P2 stores one completed-owner RR cursor per cluster. With a continuously ready
local response consumer, a completed owner is selected within at most `O`
retirement opportunities. This is not an `O`-cycle bound when the local
consumer stalls.

The P4 black-box test directly proves the P1 `K`-opportunity bound. It does not
independently prove the P2 `O`-opportunity bound: that bound is source-grounded
in the closed P2 implementation and remains protected by frozen P2 scenarios 34
and 35, which the P4 freeze/live gates must rerun. P4 scenarios 08 and 09 prove
finite response backlog and stall drain, not adversarial-refill P2 fairness.
Neither bound may be relabeled as unconditional cycle latency.

## HOL characterization

The finite architecture exposes four distinct blocking classes:

1. A cluster has one scalar upstream head. Once same-home pressure fills its
   P3, P1, and P0 request holds, a later free-home request from that cluster is
   hidden. A different cluster targeting the free home still progresses.
2. A full `Q`-entry L2 miss table blocks another miss at that slice while an
   independent slice remains live.
3. A stalled cluster response holds one P0 response and serializes later
   completed owners for that cluster. Other clusters retain independent output
   lanes.
4. Backend responses have strict priority over the one-entry L2 hit response
   hold. A continuous legal backend-response stream can postpone that hit
   without a finite cycle bound.

The XOR home map can also concentrate adversarial addresses on one slice.
Balanced addresses can reach `min(K,S)` backend requests in one opportunity;
same-home traffic is limited to one request per slice opportunity.

Deeper scalar FIFOs absorb bursts but do not remove destination HOL. Finite
per-destination VOQs can mitigate HOL until the selected queue fills. Multiple
injection or response lanes require a changed public cluster contract and
cannot be obtained by modifying only P3 internals.

## Behavioral proof contract

The full black-box test emits literal ordered PASS markers for:

1. reset, a complete miss round-trip, and conservation;
2. sustained same-home RR service-opportunity bounds;
3. balanced distinct-home `min(K,S)` throughput;
4. full-hold same-cycle ready sensitivity;
5. stalled payload stability;
6. scalar request HOL;
7. progress by another cluster despite that HOL;
8. boundary-scoped `O+1` completed-response retention;
9. lossless response drain;
10. simultaneous responses from all slices;
11. `Q` miss saturation;
12. independent-slice progress under saturation;
13. balanced hash mapping;
14. hotspot serialization;
15. backend-response priority postponing a buffered hit;
16. reset flushing held/in-flight transport state;
17. bubble-free same-slice request turnover;
18. non-power-of-two cluster/CU identity and opaque tag preservation; and
19. final multi-cluster conservation and drain.

Every other required configuration performs a public-port miss/refill/response
functional smoke. The P4 runner verifies exact marker order, absence of extra
PASS lines, zero warning lines, dependency identity, public-port-only testing,
and `/tmp` build containment.

## Decision rule

P4 preserves the simpler architecture unless a measured result violates an
explicit target:

- a ready-cone frequency target can motivate a fully registered credit or skid
  boundary;
- a multi-destination HOL target can motivate finite per-slice VOQs;
- a burst-absorption target can motivate deeper finite queues;
- a per-cluster rate above one line/cycle requires multiple public lanes; and
- failed `K=64,S=64` area/timing targets can motivate hierarchical routing or a
  physical NoC rather than a flattened total-CU fabric.

Source-loop cardinality, simulation latency, and Verilator runtime alone do not
constitute a physical timing failure.

## Rollback boundary

P4 consists of this document, one black-box testbench, and one runner. Omitting
those three files completely removes the milestone. P0, P1, P2, P3, sliced L2,
production RTL, the live repository, and canonical frozen artifacts remain
unchanged.
