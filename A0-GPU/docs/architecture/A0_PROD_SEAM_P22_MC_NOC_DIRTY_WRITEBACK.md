# PROD-SEAM-P22 — logical MC-NoC requester routing into recoverable dirty/writeback L2

P22 composes the frozen line-slice request/response fabric with the frozen P21 multi-slice recoverable dirty/writeback bank. A client request keeps its exact `{client_id, local_tag}` identity through home-slice selection, dirty-victim hold, durable writeback completion, replacement refill, and response restoration. The L2 bank treats the global requester tag as opaque.

Dirty eviction is now exercised behind the same logical multi-client routing foundation used by the sliced-L2 path. A dirty same-set replacement does not emit its backend read until the originating home slice receives its exact durable writeback `SUCCESS`. Writeback statuses may complete out of order across slices without swapping client identity or releasing the wrong replacement request.

P22 deliberately keeps store updates slice-local. It does not invent a partially accepted global multi-lane store fanout on top of the P17 store-ready contract. Connecting successful production store commits and their exact write data into the correct home slice is the next bounded milestone.

P22 remains a logical routing composition, not a physical mesh/ring NoC, ownership/snoop coherence protocol, VRAM partition scheduler, or full global memory-ordering model.
