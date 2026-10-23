# A0 RTL8A — Multi-Outstanding / MSHR Foundation

Status: **standalone foundation candidate**.

RTL8A is the first synthesizable A0 structure that can represent more than one
outstanding global-memory line at the same time. It deliberately stops at the
MSHR-table boundary: the live RTL7C `VLOADX/VSTOREX` path is not rewired to the
table in this milestone. That integration is RTL8B.

## Why this is separate from RTL7C

RTL7C proved the correctness boundary for a single wave-tagged backend
transaction:

- the memory owner wave blocks,
- another resident wave can continue compute,
- responses return to the correct context,
- load refill preserves scoreboard ownership.

The next risk is no longer basic wave tagging. It is **multiple outstanding
ownership**:

- duplicate line tags,
- finite capacity,
- same-line merging,
- unsent miss requests,
- out-of-order responses,
- merged waiter fanout,
- slot reclamation and reuse.

Those contracts are easier to verify in isolation before changing the live
execution core.

## Production module

`rtl/memory/a0_mshr_table.sv`

Default/target parameters are configurable:

```text
MSHR_COUNT       = 2 / 4 / 8 / 16 / 32
RESIDENT_WAVES   = implementation dependent
WAVE_SIZE        = 32
LINE_WORDS       = 8   (32-byte line with 32-bit words)
LINE_ADDR_W      = configurable
VECTOR_REG_COUNT = 64
```

RTL8A does not freeze a production MSHR count.

## Entry contract

Each live entry owns exactly one cache-line tag and stores:

- valid,
- downstream-miss-issued,
- response-ready,
- fault,
- line address,
- returned line data,
- one waiter slot per resident wave.

Each waiter stores:

- context ID,
- destination vector register,
- lane mask,
- per-lane word selector within the cache line.

The word selectors are the future bridge from a coalesced line response back to
individual wave lanes.

### RTL8A waiter limitation

RTL8A permits **at most one waiter from the same resident wave in one MSHR
entry**.

That is consistent with the current in-order A0 wave model: a wave blocks after
issuing a load and therefore cannot issue a second dependent/independent load
before completion. Different resident waves can merge into the same entry.

This is a documented milestone constraint, not a permanent ISA rule. A future
out-of-order or deeper per-wave memory frontend would replace the per-wave
single waiter with a deeper waiter structure.

## Allocation and merge

For a frontend request:

1. If an open entry has the same line tag, merge the waiter.
2. If the same wave is already a waiter in that entry, reject the duplicate.
3. If that line is already in response/completion drain, backpressure it.
4. Otherwise allocate the lowest free physical entry.
5. If no free entry exists, backpressure the unique-line request.

A full table can therefore still accept a merge into an existing open line.

The table never intentionally creates two simultaneously live entries with the
same line tag.

## Downstream miss issue

Allocation is decoupled from backend readiness.

New entries begin as `issued=0`. A single issue arbiter chooses the lowest
physical unsent entry and holds:

```text
miss_req_valid
miss_req_entry
miss_req_line_addr
```

until the backend accepts the request.

This means frontend allocation can continue into other free MSHRs even when
the backend issue port is temporarily backpressured.

RTL8A uses fixed physical-entry priority only for this foundation. A later
implementation may replace it with age/fairness arbitration without changing
the MSHR ownership contract.

## Response routing

A backend response carries:

```text
{entry_id, line_addr, fault, line_data}
```

A response is accepted only if:

- the entry ID is valid,
- the entry is live,
- the miss was issued (or is accepted on the same cycle),
- the entry is not already response-ready,
- the response line tag matches the entry line tag.

A stale or misrouted response raises `resp_tag_error_o` and **does not consume
or mutate the live MSHR**.

Responses may arrive out of allocation order because routing is entry-tagged.

## Completion drain

After a valid response, the entry retains the line data and drains one waiter
per `complete_valid/complete_ready` handshake.

The completion payload contains:

- entry,
- wave,
- context,
- destination register,
- lane mask,
- per-lane word selectors,
- fault status,
- full returned line data.

The slot is reclaimed only after the final merged waiter is consumed.

While an entry is in completion drain, a new request for the same line is
backpressured for one conservative ownership boundary. RTL8A does not allocate
a duplicate line during that interval.

## Capacity telemetry

The table exposes:

```text
occupancy
full
empty
valid_mask
issued_mask
response_ready_mask
```

RTL8B can feed `occupancy / MSHR_COUNT` into the existing RTL7A scheduler
pressure interface.

The existing SIM17 policy hook therefore does not need a new definition when
real MSHRs are connected.

## Logical storage scale

With the current prototype geometry:

```text
WAVE_SIZE        = 32
LINE_WORDS       = 8
LINE_ADDR_W      = 29
RESIDENT_WAVES   = 4
context ID       = 2 bits
vector dst       = 6 bits
word selector    = 3 bits/lane
```

one entry contains approximately:

```text
control                         4 bits
line tag                       29 bits
line response data            256 bits
waiter metadata/wave          137 bits
4 wave waiter slots           548 bits
--------------------------------------
approximate logical total     837 bits / entry
```

Therefore:

```text
 2 MSHRs  ~  1,674 bits
 4 MSHRs  ~  3,348 bits
 8 MSHRs  ~  6,696 bits
16 MSHRs  ~ 13,392 bits
32 MSHRs  ~ 26,784 bits
```

This is **not** an area, timing, or power estimate. Register-vs-SRAM mapping,
ports, muxes, arbitration, response bandwidth and routing can dominate the
real hardware cost. It only shows that metadata bit count by itself does not
resolve the 16-vs-32 decision.

## Verification

### Directed MSHR contract

Proves:

- reset/empty state,
- unique-line allocation,
- same-line merge,
- duplicate-waiter rejection,
- full-table unique-line backpressure,
- merge while full,
- one downstream request per unique line,
- response-tag rejection,
- out-of-order response routing,
- slot reclaim/reuse,
- response-drain line ownership,
- merged waiter drain,
- fault fanout,
- same-cycle miss issue + correctly tagged response acceptance.

### Parameter sweep

The same production module is elaborated and filled at:

```text
MSHR_COUNT = 2, 4, 8, 16, 32
```

Every configuration must reach exact full occupancy and reject one additional
unique line.

### 10,000-cycle Python ↔ RTL differential

The randomized differential uses:

```text
MSHR_COUNT      = 4
RESIDENT_WAVES  = 3
WAVE_SIZE       = 4
LINE_WORDS      = 4
```

Three waves intentionally use a 2-bit wave ID so invalid wave ID `3` is also
exercised.

The random stream covers:

- allocations,
- merges,
- duplicate waiters,
- full-table stalls,
- drain-time same-line stalls,
- backend issue backpressure,
- accepted responses,
- bad response tags,
- response faults,
- completion backpressure,
- entry reuse.

The Python model additionally asserts every cycle that:

- live line tags are unique,
- every live entry retains at least one waiter,
- response-ready entries were issued,
- waiter wave IDs and metadata shapes are valid.

## What RTL8A does not claim

RTL8A does not yet provide:

- live-core MSHR integration,
- multiple outstanding `VLOADX` from the actual execution core,
- cache hit/miss lookup,
- real L2 fill path,
- store buffer / store merging,
- atomics,
- TLB/page walks,
- DRAM channel/bank contention,
- response bandwidth modelling,
- adaptive-v1 hardware policy,
- final MSHR capacity.

## Next: RTL8B

RTL8B should connect the proven table to the live multi-wave memory path:

1. split/coalesce active `VLOADX` lanes into line requests,
2. allocate or merge each distinct line into an MSHR,
3. keep wave-qualified destination scoreboard ownership until all line waiters
   for that architectural load complete,
4. route out-of-order line responses into context-qualified VRF refill,
5. expose real MSHR occupancy/full and same-line merge opportunities to the
   scheduler boundary,
6. prove at least two different cache lines are outstanding concurrently while
   other waves continue execution.

Only after RTL8B should the SIM16 16-vs-32 capacity study be compared against
real RTL timing/resource cost.
