# A0 PROD-SEAM-P3 — Global Physical-Store Invalidation

## Scope

P3 preserves the closed P2 production multi-cluster load/refill composition and
adds conservative cache-domain visibility for physical stores.  Every P1
cluster store-observation stream is flattened into one global store vector and
broadcast to every sliced-L2 bank.  The existing `a0_l2_line_cache` primitive
uses that observation to invalidate matching resident lines and mark matching
in-flight refill installation as killed.

This is a coherence prerequisite, not full coherent-store completion.

## Production path

Load/refill path remains unchanged:

`core/CU -> private L1 -> MSHR -> local fabric -> P0 seam -> MC-NoC -> sliced L2 -> backend`

Store visibility path added by P3:

`cluster physical-store ordering observation -> global flatten -> every L2 slice store-observe port`

The actual store write data continues through the existing legacy memory
request/response path.  P3 deliberately adds no write allocation, dirty state,
writeback, atomics, ownership protocol, snoop response, or VRAM-controller
policy.

## Required qualification

- exact Verilator 5.050 strict-all lint, with no Verilator `-Wno-*` leak;
- P2 baseline multi-cluster load/refill behavior remains intact;
- one cluster store observation is visible in the global flattened vector;
- a store to a line cached by another cluster invalidates that shared-L2 line;
- invalidation reaches multiple L2 home slices in the same store observation;
- post-store loads miss stale cache state and receive newly supplied backend data;
- diagnostics remain clean;
- closed P2 predecessor gate remains PASS.

## Explicit non-claims

P3 does **not** make in-flight pre-store loads retry or squash stale backend
responses, and it does not implement a full cache-coherence protocol.  Those
need a later ordering/coherence milestone with an explicit retry/ownership
contract.
