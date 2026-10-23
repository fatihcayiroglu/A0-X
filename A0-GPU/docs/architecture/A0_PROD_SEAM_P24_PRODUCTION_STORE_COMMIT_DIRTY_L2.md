# PROD-SEAM-P24 — production store-commit to dirty-L2 composition

P24 connects the frozen P7-shaped physical-store visibility-commit contract to the frozen P23 multi-client dirty/recoverable L2 store-update seam. It does not alter the original 49-file tracked warning-clean patch and does not replace any closed predecessor artifact.

## Commit fanout contract

`a0_store_commit_dirty_l2_router` selects one commit source with bounded round-robin arbitration and keeps that source locked until the commit is complete. Every active store lane is routed by its exact captured **word address** through the same line/home-slice hash used by `a0_line_slice_fabric`; write data is copied unchanged. Requester or slice identity is never reconstructed from payload data.

A commit spanning several home slices may be accepted by those slices on different cycles. The router records each accepted slice and suppresses that slice thereafter, so an already accepted update cannot be duplicated while another slice remains backpressured. Upstream `commit_ready_o` is asserted exactly once and only when every required slice has accepted its own lane subset. A zero-active-lane commit is therefore an immediate no-op acknowledgement.

This deliberately allows **partial slice update before the final upstream acknowledgement**. It is not a claim of simultaneous globally atomic visibility. The safety contract comes from the frozen P7/P6 predecessor semantics: while `commit_valid` is held and P24 withholds `commit_ready`, the successful physical store remains pending upstream, so conflicting loads/replays remain blocked until the last required dirty-L2 slice accepts its portion. Non-conflicting activity remains eligible to progress.

The P17 dirty-slice policy remains unchanged. A resident store hit updates the exact word and marks the line dirty. A store miss is reported as a miss and remains no-write-allocate; P24 does not silently allocate a new dirty line. The physical store itself has already completed on the predecessor store path before the P7 visibility-commit is raised.

## Backpressure and ordering

The router never makes `slice_store_valid` or slice payload depend on downstream `slice_store_ready`; only completion accounting depends on ready. This avoids the ready/valid combinational cycle found in the first P24 composition attempt. Once any slice accepts part of a commit, source selection remains locked and the source must obey the standard valid/payload-stability contract until final ready.

The top-level `a0_production_store_commit_dirty_l2_subsystem` composes this router with frozen P23. Refill reads and durable dirty-victim writebacks continue to use P23's typed unified line-backend command seam unchanged.

## Proven behavior

Directed qualification proves:

- exact multi-lane word-address/write-data home-slice routing;
- one commit spanning several slices;
- partial slice acceptance without duplicate re-application;
- upstream acknowledgement withheld until the final required slice acceptance;
- bounded round-robin progress among commit sources;
- resident store commits update dirty L2 lines on multiple slices;
- post-commit L2 hits return the newly committed values without redundant backend reads;
- later dirty eviction writes back the exact committed data;
- requester identity remains intact after durable writeback and replacement refill;
- final queue/cache diagnostics drain cleanly.

## Deliberate bounds

P24 does **not** claim simultaneous global atomic visibility, ownership/snoops, MESI/MOESI, dirty sharing between agents, atomics, a physical VRAM controller, DRAM timing, complete global memory ordering, or a globally coherent CPU/GPU memory system. Those require later bounded milestones and independent proof.
