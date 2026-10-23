# PROD-SEAM-P17 — Shared-L2 dirty/writeback foundation

P17 is the first bounded write-back cache milestone. It adds a successor shared-L2 slice primitive without changing the frozen P0–P16 production seam or the original 49-file warning-clean tracked patch.

## Contract

`a0_l2_dirty_writeback_slice` is a direct-mapped, parameterized shared-L2 slice with one bounded outstanding refill. A successful refill installs a **clean** line. A store that hits a resident line updates the resident word and sets explicit dirty state. P17 stores are no-write-allocate; a store miss is reported and does not silently allocate a dirty line.

When a load miss maps onto a **dirty** resident line, the requester identity and requested line are retained and the complete victim line is captured on the writeback interface. The victim remains valid and dirty while `wb_valid_o && !wb_ready_i`. The retained backend read cannot issue during that interval. Only an actual `wb_valid_o && wb_ready_i` handshake may invalidate/clean the victim and release the retained refill request. This is the P17 no-synthetic-clean rule.

The victim payload is stable under writeback backpressure. A store targeting the active victim is backpressured so the captured writeback image cannot diverge from the dirty cache state being evicted. Clean conflicts may evict without writeback. Faulted refills are forwarded but never installed. Untracked backend responses are contained as protocol errors rather than emitted as architectural responses.

## Scope boundary

P17 deliberately does **not** convert the existing P16 store visibility path from backing-memory commit to write-back policy. Doing so would silently change a frozen predecessor contract. P17 provides the real dirty/victim/writeback primitive needed for that future composition; a later bounded milestone must connect production store commits to the dirty L2 and arbitrate writebacks with the unified backend.

P17 also does not claim ownership, snoops, MESI/MOESI state, dirty sharing between slices, atomics, full global ordering, writeback completion/status retry, VRAM partitioning, or deadlock/fairness proof.

## Required proof

Canonical qualification requires exact Verilator 5.050, strict `-Wall` lint with no RTL `-Wno-*`, three parameter variants, directed dirty/writeback behavior, frozen P16 receipt/artifact identity, strict outer/inner suppression leak 0/0, and repository containment.
