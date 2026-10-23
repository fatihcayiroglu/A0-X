# A0 RTL9C-1 — Core-Level L1 End-to-End Proof

RTL9C-1 is a tests-only milestone.

No production RTL is changed.

The objective is to prove that the L1 integrated by RTL9B-2 works through
the real `a0_multi_wave_core` execution path rather than only through the
memory-service-boundary testbench.

## Proven path

A VLOADX travels through:

`a0_multi_wave_core`
→ `a0_wave_load_mshr_bridge`
→ `a0_memory_service_boundary`
→ `a0_l1_line_cache`

Only an L1 miss is allowed to reach the external `mshr_mem_req_*` backend.

A successful external line refill returns through:

external line backend
→ L1
→ MSHR bridge
→ architectural vector destination.

## V1 scenarios

RTL9C-1 V1 proves:

- cold VLOADX reaches the external line backend;
- a successful refill completes the architectural load;
- refill data reaches the wave vector destination;
- a second load to the same line is served from L1;
- an L1 hit suppresses an external backend request;
- VLOADX never uses the legacy wave-memory read path;
- a physical legacy store to the cached line invalidates it;
- a following load to that line misses again;
- a physical store to another line does not evict the cached line;
- two waves can subsequently consume the cached line without a backend miss;
- the MSHR and architectural memory state fully drain.

## Scope

Exactly four new files are permitted:

1. this document;
2. the RTL9C-1 full-core testbench;
3. the targeted RTL9C-1 runner;
4. the RTL9C-1 regression gate.

No existing file may change.

## Non-goals

RTL9C-1 does not add or modify:

- cache RTL;
- core RTL;
- boundary RTL;
- MSHR RTL;
- store-queue RTL;
- cache geometry;
- replacement policy;
- write allocation;
- writeback;
- dirty state;
- coherence;
- translation;
- memory-controller behavior.

Faulted-refill cacheability is intentionally left for the next test revision
after the fundamental end-to-end V1 sequence is proven.

## Faulted refill core proof

RTL9C-1 additionally proves the faulted-refill policy through the
real `a0_multi_wave_core` load path rather than only at the isolated
L1 or memory-boundary level.

The core-level sequence is:

1. A cold `VLOADX` to word base 240 / line 30 reaches the external
   MSHR line backend.
2. A correctly tagged backend response is returned with `fault=1`.
3. The fault response is observed at the real
   `load_mshr_complete_valid && load_mshr_complete_ready` core
   completion handshake with `load_mshr_complete_fault=1`.
4. Memory/MSHR ownership fully drains.
5. Without any intervening reset, an independent wave executes a
   `VLOADX` to the same line 30.
6. That second access produces another external backend miss,
   proving the faulted refill was not installed in L1.
7. A successful retry refill reaches the destination vector register.

The retry occurs without resetting the cache between steps 2 and 5,
so the second physical backend request is a direct end-to-end proof
of the no-install-on-fault policy.

`FAULTED_REFILL_EDGE=CORE_LEVEL_PROVEN`
