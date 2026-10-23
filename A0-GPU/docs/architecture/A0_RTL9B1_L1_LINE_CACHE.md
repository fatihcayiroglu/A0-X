# A0 RTL9B-1 — Direct-Mapped L1 Line-Cache Primitive

RTL9B-1 introduces the first real cache-state primitive in A0-GPU without
changing live `a0_multi_wave_core` behavior. Integration is intentionally
deferred to RTL9B-2.

## Locked organization

- cache line: 8 x 32-bit words = 32 bytes
- default set count: 64
- associativity: 1 way (direct mapped)
- default data capacity: 2 KiB
- set count is parameterized
- tag/data arrays are not reset; valid bits are reset

The 2 KiB default is a verification-oriented foundation, not a final
high-performance L1 capacity target.

## Client and backend contract

The cacheable client is the existing MSHR line channel. A cache miss preserves
the existing ready/valid request `{entry,line}` contract. Backend responses keep
the existing no-ready `{entry,line,fault,full-line-data}` response contract.

Hits are not returned combinationally. A hit is captured into a one-entry local
response buffer and becomes visible on the client response port after the
accepting clock edge.

Backend responses have priority over a buffered hit because backend responses
cannot be backpressured. A buffered hit survives such a collision and is emitted
on the next backend-response-free cycle.

## Store policy

Legacy stores bypass the cache and never wait for it.

On store launch:

1. every matching valid cached line is invalidated;
2. every already-accepted matching line miss is marked killed;
3. a same-cycle newly accepted matching miss captures the kill state.

Store invalidation is conservative. If the architectural store later faults,
the invalidation may remain; this can only create a later cache miss.

## Refill policy

Every backend response is forwarded to the MSHR-facing response port.

A successful refill is installed only when:

- the response matches local accepted-miss metadata;
- the response is not faulted;
- the miss was not killed by a matching store;
- there is no matching store launch in the response cycle.

This prevents an older in-flight load response from reinstalling stale data
after a younger store has invalidated the line.

RTL9B-1 has no write allocate, dirty state, writeback, associativity,
replacement metadata, coherence protocol, TLB, NoC, or memory-controller logic.

## RTL9B-1 verification matrix

The dedicated test proves reset invalidity, cold miss pass-through, refill and
second-request hits, one-cycle hit buffering, backend-response collision
priority, faulted-refill suppression, single- and multi-line store invalidation,
conservative invalidation, refill kill/forward behavior, same-cycle
store/refill precedence, direct-mapped conflict replacement, response identity,
and set-count parameterization.

RTL9B-2 will integrate this proven primitive at the RTL9A memory-service
boundary and re-run the complete live-core regression chain.
