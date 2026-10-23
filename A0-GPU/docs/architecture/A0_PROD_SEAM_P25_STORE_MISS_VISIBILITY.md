# PROD-SEAM-P25 — no-write-allocate store-miss visibility

P25 closes the bounded visibility hole left intentionally by P24: a physical-store visibility commit may contain a lane that misses the resident dirty L2 because P17/P24 use a no-write-allocate store policy. P25 preserves frozen P24 and adds the minimum ordered successor contract needed so that acknowledging such a commit cannot be followed by a refill from the same backend visibility domain returning data older than that committed store lane.

## Ordered commit contract

`a0_production_store_commit_write_miss_visibility_subsystem` selects one P7-shaped commit source with bounded round-robin arbitration and captures its exact lane mask, word addresses, and write data. The selected source remains active until acknowledgement and must keep valid asserted through the valid/ready handshake.

The captured commit is first presented unchanged to frozen P24. Resident lanes continue to use the P24/P17 dirty-L2 fast path: they update the exact resident word, become dirty, and are later protected by the existing durable full-line writeback machinery. P25 observes P24's explicit per-slice hit/miss classification and accumulates only lanes that were classified as store misses.

A store-miss lane is **not allocated into L2** and P25 does not perform a read-modify-write. Instead, after the P24 resident update phase completes, every captured miss lane is emitted exactly once as a typed `STORE_WORD` command carrying the original 32-bit word address and 32-bit write data. These commands share the same external visibility-domain boundary used by P23 refill reads and dirty-victim writebacks. While miss lanes are draining, P23 line commands are backpressured rather than allowed to pass the pending commit.

Upstream `commit_ready` is withheld until every required `STORE_WORD` command has been accepted. Acceptance of the last store-word command is therefore the bounded visibility point for the miss portion of that commit. A later refill command through this same ordered backend boundary cannot legally precede the acknowledged store-miss lane. Backend storage semantics beyond accepted command order remain an external contract; P25 is not a physical VRAM controller.

## Backpressure and identity

The selected commit source is locked while the transaction is active. Exact word address/data are captured before P24 presentation and are never reconstructed from cache contents, requester tags, or payload heuristics. Under backend backpressure, `STORE_WORD` valid/address/data remain stable. Each accepted miss lane is cleared from the pending mask exactly once, preventing duplicate writes and duplicate commit acknowledgement.

Resident-hit and store-miss masks are checked for overlap or classification outside the captured active-lane mask. Such inconsistency contributes to `protocol_error_o`; no dummy sink hides the classification contract.

## Proven behavior

Directed qualification proves:

- preload of a resident line through the frozen P23 refill path;
- a single commit containing one resident-hit lane and one no-write-allocate miss lane;
- exact store-miss word address/data stability under backend backpressure;
- upstream commit acknowledgement held until the miss word reaches the backend visibility boundary;
- exactly-once miss-word publication;
- bounded round-robin progress between commit sources;
- resident-hit lane remains on the dirty-L2 fast path without redundant store-word traffic;
- after commit acknowledgement, a load of the former miss line refills and observes the newly committed store word;
- frozen P23 typed durable writeback still carries the exact resident-hit dirty data during later eviction;
- final writeback/recovery/cache diagnostics drain cleanly.

## Deliberate bounds

P25 does **not** claim a physical VRAM/DRAM controller, persistent durability of an accepted `STORE_WORD`, byte/partial-write support beyond the 32-bit word contract, globally atomic multi-lane stores, ownership/snoop coherence, MESI/MOESI, CPU/GPU coherence, atomics, complete global memory ordering, or a full memory-consistency model. Those remain later bounded milestones.
