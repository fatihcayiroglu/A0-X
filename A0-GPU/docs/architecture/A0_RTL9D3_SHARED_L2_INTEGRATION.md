# A0 RTL9D-3 — Requester-tagged fabric + shared L2 integration

## Status

RTL9D-3 composes the already-closed RTL9D-1 requester-tagged line fabric
with the already-closed RTL9D-2 shared non-blocking L2 line cache.

The milestone remains isolated from production multi-CU wiring.

## Topology

Client line requests flow through:

    clients
      |
      v
    a0_line_request_fabric
      |
      | opaque global_tag
      v
    a0_l2_line_cache
      |
      v
    external line backend

Backend line responses return through:

    external backend
      |
      v
    a0_l2_line_cache
      |
      | opaque global_tag
      v
    a0_line_request_fabric
      |
      v
    exact originating client

## Global requester identity

The fabric derives:

    CLIENT_ID_W =
      (CLIENT_COUNT <= 1)
        ? 1
        : $clog2(CLIENT_COUNT)

    GLOBAL_TAG_W =
      CLIENT_ID_W + LOCAL_TAG_W

The L2 receives the complete global tag but treats every bit as opaque.

The L2 must not decode requester or local-tag fields.

The fabric alone performs response requester validation and local-tag
restoration.

## Store observation

Store transactions do not pass through the line-request fabric.

Each client exposes conservative physical-store observation metadata:

    client_store_valid_i
    client_store_lane_mask_i
    client_store_word_addr_i

The integration wrapper flattens all clients into the existing L2 store
observer.

For:

    L2_STORE_LANES =
      CLIENT_COUNT * STORE_LANES_PER_CLIENT

flattened lane:

    flat =
      client * STORE_LANES_PER_CLIENT
      + lane

is active when:

    client_store_valid_i[client]
    && client_store_lane_mask_i[client][lane]

The corresponding word address is copied exactly.

This lets simultaneous stores from different clients invalidate multiple
shared-L2 lines and kill matching outstanding refills in one cycle.

## Real store lane-width contract

The live core has:

    WAVE_SIZE = 32
    PHYSICAL_LANES = 8

The physical store observation interface is wave-wide, not execution-beat
wide.

Therefore:

    STORE_LANES_PER_CLIENT

is parameterized with prototype default:

    32

This default follows the real `WAVE_SIZE` store-observation contract.

`PHYSICAL_LANES=8` is not the store-observation width.

## Wrapper defaults

    CLIENT_COUNT = 4
    LOCAL_TAG_W = 2
    STORE_LANES_PER_CLIENT = 32
    LINE_WORDS = 8
    L2_SET_COUNT = 256
    L2_MISS_COUNT = 16

`L2_SET_COUNT=256` remains only a prototype default.

Final L2 capacity and associativity remain unfrozen.

## Response channel

The integrated line-response path has no ready/backpressure signal.

The RTL9D-2 L2 therefore retains backend-response priority over its local
buffered-hit response.

The RTL9D-1 fabric demultiplexes every valid response according to the
global requester tag.

Malformed requester encodings are rejected without client fanout and are
reported through the wrapper's `line_resp_tag_error_o`.

## Behavioral integration configuration

The focused integration test uses:

    CLIENT_COUNT = 3
    LOCAL_TAG_W = 2

Therefore:

    CLIENT_ID_W = 2
    GLOBAL_TAG_W = 4

Requester encoding `2'b11` is unused and is used to prove malformed-tag
rejection end to end.

The focused test may use smaller L2 set/miss and store-lane parameters
without changing wrapper defaults.

## Required end-to-end proofs

RTL9D-3 proves:

1. reset idle;
2. client0 cold miss reaches external backend;
3. fabric global tag reaches L2 opaquely;
4. L2 preserves global tag to backend;
5. refill routes to client0;
6. client0 local tag restored;
7. client1 same-line shared-L2 hit;
8. cross-client hit suppresses backend;
9. client1 local tag restored;
10. same local tag on different clients gets distinct global tags;
11. those requests may be concurrently outstanding;
12. multiple outstanding misses from multiple clients;
13. external responses may return out of order;
14. OoO responses route to the correct clients;
15. OoO local tags are restored;
16. L2 tracker-full backpressure propagates through fabric;
17. held fabric payload remains stable under L2 backpressure;
18. fabric round-robin fairness remains visible with L2;
19. client1 store invalidates line filled for client0;
20. client0 reload after that store misses;
21. client2 store kills client0 outstanding refill;
22. killed refill still routes to client0;
23. killed refill does not install;
24. same-cycle cross-client store/refill gives store install priority;
25. simultaneous stores from multiple clients flatten correctly;
26. simultaneous stores invalidate multiple shared lines;
27. faulted refill routes to the originating client;
28. faulted refill does not install;
29. malformed requester tag is rejected;
30. malformed requester causes no client fanout;
31. malformed requester raises tag error;
32. final L2 miss tracker drains;
33. final fabric holding state is idle;
34. final integration TB pass.

## Existing RTL

RTL9D-3 does not modify:

- `a0_line_request_fabric`;
- `a0_l2_line_cache`;
- `a0_l1_line_cache`;
- `a0_memory_service_boundary`;
- `a0_multi_wave_core`.

## Non-goals

RTL9D-3 does not implement:

- production multi-CU instantiation;
- production core or boundary rewiring;
- coherence;
- write allocation;
- dirty state;
- writeback;
- same-line L2 miss merging;
- cache banking;
- final L2 associativity;
- final L2 capacity;
- TLB/MMU;
- NoC;
- DRAM scheduling;
- DRAM controller policy.

## Scope

Exactly five files are added:

1. `docs/architecture/A0_RTL9D3_SHARED_L2_INTEGRATION.md`
2. `rtl/memory/a0_shared_l2_subsystem.sv`
3. `tests/rtl/a0_shared_l2_subsystem_tb.sv`
4. `tests/run_rtl9d3_shared_l2_integration.py`
5. `tests/run_rtl9d3_gate.py`

`RTL9D3_REQUESTER_TAGGED_FABRIC_SHARED_L2_INTEGRATION=DEFINED`
