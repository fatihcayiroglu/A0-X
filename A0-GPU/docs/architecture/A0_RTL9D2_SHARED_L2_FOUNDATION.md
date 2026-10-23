# A0 RTL9D-2 — Shared L2 line-cache foundation

## Status

RTL9D-2 introduces an isolated shared-L2 line-cache primitive.

It is deliberately not connected to the live core, the RTL9D-1 line fabric,
or the memory-service boundary in this milestone.

RTL9D-3 is reserved for integration.

## Purpose

RTL9D-1 established a globally unique requester-tagged line transaction:

    {opaque global_tag, line_addr}

RTL9D-2 adds the first hardware L2 storage and miss-tracking layer downstream
of that contract.

The L2 treats `global_tag` as opaque.

It does not decode client IDs or local MSHR tags.

## Real RTL line geometry

The hardware foundation follows the frozen RTL8/RTL9 line geometry:

- 32-bit words;
- 8 words per line;
- 32-byte lines.

The timing-model SIM13 64-byte example is not a frozen hardware line size.

## Mapping

The RTL9D-2 foundation is direct mapped.

`SET_COUNT` is parameterized.

The prototype default is:

    SET_COUNT = 256

At 8 words x 4 bytes per line, this is:

    256 * 32 bytes = 8192 bytes

This 8 KiB value is a prototype default only.

It is not a frozen production shared-L2 capacity.

Final L2 capacity and associativity remain future architecture decisions.

## Opaque global tag contract

The client request contains:

    global_tag
    line_addr

A miss forwarded to the backend preserves both values exactly.

A backend response forwarded upstream also preserves both values exactly.

The L2 must never infer or decode:

- client ID;
- local MSHR ID;
- requester namespace layout.

This keeps the primitive independent from future CU-count scaling.

## Hit path

A matching valid direct-mapped line produces an L2 hit.

The hit:

- suppresses the backend request;
- preserves the request's opaque `global_tag`;
- preserves the requested line address;
- returns the complete cached line;
- returns `fault=0`.

Hits are captured in a one-entry local hit buffer.

The external response channel has no ready/backpressure signal.

A backend response therefore has priority over a buffered hit.

A buffered hit survives such a collision and is returned on a later cycle.

## Non-blocking miss tracking

RTL9D-2 is not a single-blocking-miss cache.

It contains `MISS_COUNT` explicit outstanding-miss slots.

The prototype default is:

    MISS_COUNT = 16

Each valid slot stores:

- opaque `global_tag`;
- `line_addr`;
- store-kill state.

The miss-slot structure is indexed by a local slot number, not by numeric
`global_tag`.

Therefore miss-storage cost does not grow as `2^GLOBAL_TAG_W`.

## Global-tag reuse rule

A new request cannot be accepted while its `global_tag` is already present in
an outstanding miss slot.

This avoids ambiguous response ownership.

A later request may reuse the same tag after the previous miss is resolved.

## Same-line requests

Different global tags may independently miss the same line.

RTL9D-2 does not merge them.

Same-line L2 miss merging is explicitly deferred.

## Miss acceptance

A cache miss is accepted only when:

- its global tag is not already outstanding;
- a free miss slot exists;
- the downstream backend accepts the request.

The request's global tag and line address are forwarded unchanged.

## Backend responses

Backend responses may arrive out of order.

A tracked response is matched against:

    {global_tag, line_addr}

A tracked slot is freed when its matching response arrives.

Every backend response is forwarded upstream, including:

- successful responses;
- faulted responses;
- responses for store-killed misses;
- untracked responses.

An untracked response does not modify cache storage.

## Refill installation

A backend response installs into L2 only when all conditions hold:

- the response matches a tracked miss;
- the response is not faulted;
- the tracked miss was not killed by a store;
- no same-cycle physical store touches the response line.

Faulted responses are forwarded but never installed.

Store-killed responses are forwarded but never installed.

Untracked responses are forwarded but never installed.

## Physical-store observation

Physical stores themselves do not flow through the L2 request path.

The primitive observes store-launch metadata:

- `store_valid_i`;
- active lane mask;
- per-lane word addresses.

The store address contract remains the existing 32-bit word-address contract.

Every active store lane invalidates a matching cached line.

Every active store lane also kills every outstanding refill tracking the same
line.

This is conservative correctness plumbing, not a coherence protocol.

## Store fault behavior

Invalidation occurs at store launch.

A later store fault does not restore the old cache line.

That may create an additional later miss but cannot expose stale cached data.

## Store/refill collision

If a store and matching backend refill occur in the same cycle:

- the backend response is still forwarded;
- the refill is not installed;
- store visibility wins.

## Reset

Cache valid bits are reset.

Miss-valid and hit-buffer-valid state are reset.

Tag and cache-data arrays are not required to reset because validity controls
their architectural visibility.

## Parameter contract

Foundation parameters include:

- `STORE_LANES`, default 32;
- `LINE_WORDS`, default 8;
- `SET_COUNT`, default 256;
- `GLOBAL_TAG_W`, default 4;
- `MISS_COUNT`, default 16.

Foundation `SET_COUNT` values are powers of two.

`MISS_COUNT` is independent from `GLOBAL_TAG_W`.

## Verification contract

The behavioral test proves 31 markers:

1. reset invalid;
2. cold miss reaches backend;
3. request global tag preserved to backend;
4. successful refill forwarded;
5. successful refill installs;
6. second request hits L2;
7. hit suppresses backend;
8. hit global tag preserved;
9. shared line reuse across different global tags;
10. direct-mapped conflict replacement;
11. multiple outstanding misses;
12. out-of-order backend responses;
13. out-of-order tag preservation;
14. miss-slot-full backpressure;
15. refill frees a miss slot;
16. same-global-tag busy backpressure;
17. backend response beats buffered hit;
18. buffered hit survives backend collision;
19. faulted refill forwarded;
20. faulted refill not installed;
21. store invalidates matching cached line;
22. unrelated store preserves cached line;
23. multi-lane store invalidates multiple lines;
24. store kills outstanding refill;
25. killed refill still forwarded;
26. killed refill not installed;
27. same-cycle store/refill invalidation wins;
28. untracked backend response forwarded;
29. untracked backend response not installed;
30. final miss tracker drain;
31. final TB pass.

The targeted runner additionally elaborates/lints multiple:

- set counts;
- miss counts;
- global-tag widths;
- store-lane counts.

## Non-goals

RTL9D-2 does not implement:

- final L2 capacity;
- final associativity;
- set-associative replacement;
- same-line miss merging;
- write allocate;
- dirty state;
- writeback;
- coherence;
- TLB/MMU;
- NoC;
- cache banking;
- DRAM scheduling;
- DRAM controller behavior;
- production core wiring;
- RTL9D-1 fabric integration.

## Scope

RTL9D-2 adds exactly five files:

1. `docs/architecture/A0_RTL9D2_SHARED_L2_FOUNDATION.md`
2. `rtl/memory/a0_l2_line_cache.sv`
3. `tests/rtl/a0_l2_line_cache_tb.sv`
4. `tests/run_rtl9d2_l2_cache.py`
5. `tests/run_rtl9d2_gate.py`

No existing tracked file changes.

`RTL9D2_SHARED_L2_LINE_CACHE_FOUNDATION=DEFINED`
