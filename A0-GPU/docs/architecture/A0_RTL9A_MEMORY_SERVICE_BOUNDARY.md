# A0 RTL9A — Memory-Service Boundary Foundation

RTL9A introduces a transparent structural seam between the live multi-wave core
and the two already-verified external memory protocols. It is not a cache.

The live RTL8 path contains two contracts: the legacy wave-memory channel used
by the single-outstanding physical transaction path, and the RTL8B MSHR
line-fill channel used by non-blocking VLOADX misses. The MSHR path already
performs line-based allocation, same-line merging, entry-tagged miss issue,
out-of-order response validation and merged waiter fanout. RTL9A therefore does
not reinsert the historical RTL3 coalescer.

The legacy channel preserves its one-cycle launch pulse, wave/context response
tags, lane mask, per-lane addresses/data and fault semantics. The MSHR channel
preserves ready/valid request flow plus `{entry,line}` tagged full-line
responses.

`a0_memory_service_boundary` is combinational and transparent. RTL9A adds no
cache tags/data, hit/miss policy, arbitration, buffering, replacement, dirty
tracking, writeback, TLB, coherence, NoC, or DRAM-controller behavior.

The two protocols remain independent. Existing core/MSHR/store-queue rules
remain the owners of ordering and issue policy. External core ports are
unchanged so historical RTL7/RTL8 testbenches remain valid.

RTL9A creates the insertion point for later cache work. Any later cache
milestone must explicitly define the interaction between MSHR line fills and
lane-based writes before cache state becomes architecturally observable.
