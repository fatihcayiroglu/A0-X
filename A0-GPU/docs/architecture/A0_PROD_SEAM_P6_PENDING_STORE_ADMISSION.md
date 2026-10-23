# A0-X PROD-SEAM-P6 — Pending-store load admission and replay-storm prevention

## Scope

PROD-SEAM-P6 is the bounded successor to PROD-SEAM-P5. P5 makes stale-refill replay finite and fair. P6 prevents a load or a pending P5 replay from entering the shared L2/backend request path while the same physical-store line is still globally observable as pending.

This remains an admission-ordering milestone, not a full cache-coherence protocol. It does not add ownership states, snoops, dirty state, writeback, atomics, a complete global ordering model, or VRAM-controller coherence.

## Pending-store visibility source

The production cluster store-order controller retains the physical-store lane mask and word addresses while the store owner is pending and exposes them through the existing ordering-store observation stream until terminal completion. P6 consumes the already aggregated global observation; it does not reconstruct store identity or address from unrelated payload state.

The same-cycle launch case is included because the ordering-store observation selects launch metadata immediately, before the pending register is populated.

## Admission contract

For each selected cluster request, P6 compares the line address against every qualified global pending-store lane.

- A conflicting external load keeps `ready=0` and is not presented to P3.
- A conflicting pending P5 replay is not selected for P3 and its retry state/cursor remain unchanged.
- A non-conflicting replay retains P5 priority.
- If the oldest selected replay is blocked by a pending store, a legal non-conflicting external request with a different, unowned requester tag may bypass it. This avoids unnecessary cluster-local head-of-line blocking while preserving retry ownership.
- When the matching store observation quiesces, the held external request or retry becomes admissible through the normal ready/valid path.

No synthetic request or retry is emitted while the conflict remains live, so a long-latency physical store cannot create a backend replay storm.

## Ordering point

The bounded P6 visibility point is the terminal disappearance of the matching ordering-store observation. On the cycle that terminal completion is still represented by the pending store state, a conflicting load remains blocked. It may be admitted on a later cycle after that observation is no longer live.

P6 does not itself commit store data into backend memory. The larger memory system remains responsible for making the actual store value available by the time post-store admission is allowed.

## Identity and fault provenance

P6 never derives requester identity from address or payload data. P5 continues to own exact `{cluster, CU, local-MSHR}` retry state. Admission gating only suppresses request selection; it does not rewrite the tag. A genuine backend fault on the fresh post-store completion is forwarded unchanged and is never used as a stale/retry encoding.

## Progress claim

A conflicting request may remain backpressured for as long as a matching physical store remains pending. Once the store observation quiesces, downstream request readiness eventually occurs, and the backend/consumer eventually complete their handshakes, the request progresses through the existing P5/P3 path. Non-conflicting traffic is allowed to progress during the blocked interval, including same-cluster traffic when the conflicting request is a pending retry and a legal independent external tag is available.

## Directed qualification

The P6 directed proof covers same-cycle store/load blocking, no premature backend miss, non-conflicting cross-cluster/multi-slice progress, exactly-once post-store admission, fresh post-store completion, blocked-retry replay-storm prevention, same-cluster non-conflicting bypass, exact retry identity, no double retirement, and independent fault provenance.
