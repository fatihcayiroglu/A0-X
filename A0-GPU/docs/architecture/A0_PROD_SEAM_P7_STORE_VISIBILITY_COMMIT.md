# A0-X PROD-SEAM-P7 — Store terminal-to-backend visibility commit fence

## Scope

PROD-SEAM-P7 is the bounded successor to PROD-SEAM-P6. P6 prevents a conflicting load/replay from entering shared L2 while a physical store remains globally observable as pending, but it deliberately assumed that the store value was already visible to the refill backend when that observation quiesced. P7 removes that assumption with an explicit per-CU visibility-commit handshake.

This is still a clean/write-through visibility milestone, not a full cache-coherence protocol. It does not add dirty ownership, writeback, snoops, atomics, a complete global memory-ordering model, or VRAM-controller coherence.

## Commit point

Each production CU has an independent `a0_store_visibility_commit_fence`. The fence captures the exact lane-qualified physical-store launch metadata already emitted by the production frontend: owner wave/context, lane mask, word addresses and write data.

A successful legacy store backend response is **not** forwarded as a terminal response immediately. The fence retains that success response and raises `visibility_commit_valid_o` with the captured address/data payload. The successful store becomes terminal to the frontend only on the cycle where `visibility_commit_valid_o && visibility_commit_ready_i` handshakes.

Because the predecessor frontend does not observe terminal completion before that handshake, its existing store-order controller continues to expose the physical store through the global pending-store observation. Therefore P6 continues to block a conflicting load/replay until the external visibility domain has acknowledged the store value.

## Fault contract

A faulting store response never publishes a successful visibility commit. It is forwarded directly as a faulting terminal response and clears the pending store. Backend fault provenance is not reused as commit, stale, retry, or squash metadata.

## Buffering and backpressure

The fence contains one bounded successful-terminal holding slot per CU, matching the predecessor contract of one active legacy physical store per CU. While visibility commit ready is low:

- commit valid remains asserted;
- lane mask, addresses and write data remain stable;
- the successful terminal response remains held;
- the predecessor store observation remains pending;
- P6 continues to hold conflicting loads/replays;
- independent non-conflicting P6 traffic remains eligible to progress.

A second legacy response while the successful terminal is held is fail-stop because the predecessor CU cannot legally launch another legacy store before the held terminal is released. Same-cycle terminal release plus next store launch is explicitly supported; the new launch wins the next active-store state.

## Identity and provenance

The fence matches a store backend response against the captured wave/context owner. It never reconstructs requester identity from store address or payload data. The commit payload comes directly from the captured launch metadata. P6/P5 retain exact load requester identity and stale-retry ownership unchanged.

Unrelated/mistagged legacy backend responses continue into predecessor diagnostics when no successful terminal is held, so P7 does not hide pre-existing tag/provenance failures.

## Progress claim

A successful store may remain pending for as long as the visibility consumer backpressures the commit. Once commit ready is eventually asserted, the store terminal is released exactly once and a conflicting held load may subsequently enter P6. Different cache lines remain eligible to progress during the blocked interval. P7 introduces no global commit serialization: each CU owns an independent fence and commit channel.

## Directed qualification

The P7 directed proof causally updates the refill-backend-visible test memory only on the visibility commit handshake. It proves:

- non-conflicting load progress while the store is pending;
- successful store terminal held until commit acceptance;
- exact lane/address/data commit provenance;
- stable commit payload under backpressure;
- conflicting load held throughout the visibility fence;
- exactly one commit and one terminal release;
- post-commit load observes the value written by the commit handshake, not a manually swapped value;
- faulting store publishes no commit;
- backend fault provenance remains distinct.
