# A0 PROD-SEAM-P4 — stale refill ordering / replay

P4 is a bounded successor to P3. It does not add ownership, snoops, dirty state,
writeback, atomics, or full global memory ordering.

The P4 wrapper shadows accepted backend line misses without altering the frozen
tracked warning-clean patch. A global physical store marks every matching
shadowed refill stale. The backend completion is still delivered into P3 so the
closed P3 L2 can retire its killed miss slot, but the corresponding restored
cluster-local response is consumed internally exactly once and is never exposed
as an architectural success. The exact original `{cluster, CU, local-MSHR}` tag
and line address are then replayed through the existing P3 request path.

A retry owns one slot indexed by the preserved cluster-local tag. It first waits
for the stale restored response to be consumed, then issues one replacement
request. Repeated conflicting stores may cause repeated bounded replay events;
forward progress therefore assumes an eventually quiescent conflicting store
stream. Fault provenance is independent: a stale completion is suppressed
regardless of its backend fault bit, while a non-stale fault is forwarded
unchanged.

Same-cycle store/refill ordering is store-wins: a matching store observed in the
same cycle as backend completion classifies that completion stale and forces the
same squash/replay path.
