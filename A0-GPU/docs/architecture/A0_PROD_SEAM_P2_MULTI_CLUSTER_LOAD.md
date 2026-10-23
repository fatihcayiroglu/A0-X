# A0 PROD-SEAM-P2 — Production Multi-Cluster Load Composition

## Scope

P2 composes multiple `a0_production_cu_cluster_frontend` instances from P1
with the closed MC-NoC sliced-L2 request/response path. It is deliberately a
load/refill milestone: physical-store observation remains visible at the P2
boundary and is not consumed by shared-L2 coherence yet.

## Production path

`core/CU -> private L1 -> MSHR -> cluster-local fabric -> P0 seam`

for every cluster, followed by:

`cluster endpoint -> logical NoC request/response routing -> sliced shared L2 -> external line backend`

The P1 cluster-local tag is already `{cu_id, local_mshr_tag}`. P2 adds only the
cluster identity at the existing MC-NoC endpoint, so no requester identity is
reconstructed from payload/address data.

## Non-goals

P2 does not claim coherent stores, atomics, global memory ordering across
clusters, VRAM partition controllers, or performance closure. Those require
later dedicated milestones.

## Required qualification

- exact Verilator 5.050 strict-all lint with no `-Wno-*` reaching Verilator;
- reset/idle composition behavior;
- multi-cluster request identity uniqueness;
- request routing to a sliced-L2 backend;
- out-of-order backend response restoration to the correct cluster/local tag;
- error diagnostics remain fail-stop and distinct;
- P1 and MC-NoC predecessor regressions remain closed.
