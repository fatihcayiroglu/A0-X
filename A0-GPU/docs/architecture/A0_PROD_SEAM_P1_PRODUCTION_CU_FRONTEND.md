# A0 PROD-SEAM-P1 — Production CU Frontend to P0 Line Seam

## Status

`PROD-SEAM-P1` introduces the first production CU-cluster frontend that stops at the already-closed `PROD-SEAM-P0` L2-free line seam. It deliberately does **not** embed shared L2, NoC transport, coherence, or memory-controller policy.

## Production path

The bounded composition is:

`multi-wave cores → private L1/MSHR → cluster store-order / peer-conflict policy → per-CU registered line-request holding slots → P0 production cluster line seam`

The P0 seam exports one requester-tagged post-local-fabric line request stream, one response stream, and flattened physical-store visibility to whatever downstream cache/NoC/memory hierarchy is composed later.

## Request decoupling contract

A one-entry registered request holding slot exists per CU between the private L1/MSHR path and shared line-fabric arbitration. This is an architectural decoupling point, not a warning workaround:

- upstream acceptance does not depend combinationally on round-robin arbitration;
- held request payload is registered and stable;
- a peer-store conflict may block a held request from forwarding downstream;
- an empty slot may accept a request and wait safely for a peer-store conflict to clear;
- a consumed slot may be refilled in the same cycle;
- requester/local-MSHR identity and line address are preserved unchanged.

This removes the cross-CU ready/valid combinational loop exposed by strict-all Verilator 5.050 while preserving the physical-store ordering point at the downstream request boundary.

## Non-goals

P1 does not claim implementation of:

- multi-cluster composition;
- coherent shared cache;
- VRAM partitions or memory controllers;
- atomics or a complete GPU memory model;
- global scheduling;
- raster/texture/ROP/RT/matrix pipelines;
- compiler/driver/API support;
- synthesis, timing, PPA, or RTX-6090-class performance.

Those remain later roadmap work.

## Qualification contract

`tests/run_prod_seam_p1.py` requires exact Verilator 5.050 and runs without warning suppressions. It proves:

1. no shared L2/L2-cache/NoC block is embedded in the frontend;
2. P0 seam composition and registered request decoupling are present;
3. CU/MSHR parameter variants lint cleanly;
4. the full frontend reset/idle/wiring behavioral TB builds and simulates cleanly;
5. a real VLOADX miss is captured by the frontend registered hold, transferred into the P0 seam hold, kept payload-stable under external backpressure, handshaken exactly once, returned to the originating wave, and fully drains its MSHR;
6. the already-closed P0 seam equivalence behavior is replayed against the predecessor shared-L2 wrapper with all 34 frozen RTL9D3 markers.

A PASS from this gate is structural/behavioral integration evidence only; it is not a performance claim.
