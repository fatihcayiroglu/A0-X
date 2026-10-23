# A0 RTL8B — Live MSHR Integration

Status: **correctness proven; full WSL regression gate passes**.

RTL8B connects the independently verified RTL8A MSHR table to the live
multi-wave `VLOADX` path in `a0_multi_wave_core`.

The milestone is intentionally asymmetric:

- `VLOADX` uses the new line-oriented MSHR path by default.
- `VSTOREX` remains on the RTL7C single-outstanding legacy path.
- stores wait until all live load-MSHR traffic has drained.

This keeps load-miss concurrency measurable without inventing a store buffer or
memory-ordering model before those contracts have been designed.

## 1. Architectural flow

A live `VLOADX` still uses the existing indexed-address construction path:

```text
selected resident wave
        |
        v
physical-beat vector address construction
        |
        v
validated whole-wave word addresses
        |
        v
a0_wave_load_mshr_bridge
        |
        +--> 32-byte / 8-word line decomposition
        |
        +--> a0_mshr_table allocation / same-line merge
        |
        v
line-fill backend requests
```

Backend line responses may return out of order. The bridge routes each merged
waiter completion back to its owning wave, selects each lane's word inside the
returned line, and accumulates the result in a per-wave whole-load buffer.

Only after all active lanes of one architectural `VLOADX` have completed does
the bridge present a whole-wave completion to the core. The existing shared
context-qualified VRF refill path then writes the destination and performs the
architectural memory retirement.

## 2. Cache-line decomposition

RTL8B preserves the current **word-addressed** A0 memory contract.

With the prototype `MSHR_LINE_WORDS=8`:

```text
word_select = word_address[2:0]
line_address = word_address[31:3]
line size = 8 words = 32 bytes
```

All active lanes of one load that map to the same line are grouped into one
MSHR waiter. A single architectural load may therefore own multiple MSHR
entries when its lanes span multiple lines.

## 3. Same-line merging

`a0_mshr_table` remains the ownership authority for live line misses.

Different resident waves that request the same live line merge into the same
entry. Each waiter retains:

- wave ID,
- VRF context ID,
- destination vector register,
- architectural lane mask,
- per-lane word select.

The external backend therefore sees one physical line request even when more
than one wave is waiting for that line.

RTL8B keeps the RTL8A restriction of at most one waiter per resident wave per
MSHR entry. This matches the current in-order wave model, where a wave cannot
issue a second architectural instruction while its prior `VLOADX` is
`memory_waiting`.

## 4. Multiple outstanding loads

The live core parameter is:

```text
MSHR_COUNT
```

RTL8B uses `MSHR_COUNT=2` as the focused correctness point, not as a production
choice.

The production top remains parameterized and the verification gate performs
strict elaboration/lint at:

```text
2, 4, 8, 16, 32 MSHRs
```

This preserves the SIM16 evidence that 16 and 32 are the important future
prototype points without freezing either count before RTL cost/timing work.

## 5. Per-wave load ownership

`a0_wave_load_mshr_bridge` keeps one logical load transaction per resident
wave:

- active state,
- context ID,
- destination register,
- expected active-lane mask,
- lanes not yet allocated to line entries,
- lanes already completed,
- accumulated fault state,
- validated word addresses,
- assembled lane data.

A wave becomes architecturally `memory_waiting` when its whole `VLOADX` is
accepted into this bridge. Other ready waves may continue using the shared
execution engine.

The bridge may temporarily hold a wave whose next unique line cannot allocate
because the MSHR table is full. This is bounded by the resident-wave count and
is distinct from the line-MSHR capacity itself.

RTL8B has one line-allocation request port and a simple round-robin wave head.
A full-table unique-line request at that head may temporarily delay a mergeable
request from another wave until table progress occurs. This is a known
head-of-line performance limitation, not a correctness failure; later allocator
work may add merge-aware lookahead.

## 6. Backend request and response contract

The new live line backend interface contains:

```text
request:
    valid / ready
    MSHR entry ID
    line address

response:
    valid
    MSHR entry ID
    line address
    fault
    full line data
```

The response must match both entry ID and line address. A stale or misrouted
response:

- raises the MSHR tag-error indication,
- raises the core memory-tag-error indication,
- does not consume the live entry,
- does not release any wave scoreboard state.

Correct responses may arrive in a different order from request issue order.

## 7. Completion and VRF refill

Line completion and architectural load completion are separate levels.

The MSHR table drains one waiter at a time into the bridge. The bridge can
therefore consume multiple line/waiter completions while another architectural
load is waiting for the shared VRF refill path.

When one wave's entire load is complete, the core serializes:

```text
whole-wave completion
        |
        v
context-qualified VRF refill beats
        |
        v
memory completion retirement
        |
        +--> clear memory_waiting
        +--> release wave-qualified destination scoreboard
```

The single shared VRF write port is deliberately preserved. RTL8B increases
memory-level parallelism without pretending that the current refill path has
multi-write bandwidth.

## 8. Pause behavior

Backend line responses are accepted by the MSHR table independently of
`run_enable`.

When `run_enable=0`:

- line responses may be buffered,
- MSHR waiter data may be accumulated by the bridge,
- architectural VRF refill does not advance,
- architectural retirement does not occur,
- wave/context ownership remains intact.

Resume continues from the buffered completion state.

## 9. Store ordering boundary

RTL8B does not yet define a general load/store ordering model.

`VSTOREX` therefore remains on the legacy RTL7C transaction path and is not
allowed to launch while the load-MSHR bridge has live traffic.

This is intentionally conservative. Later work must explicitly design and
verify:

- store buffering,
- load/store ordering,
- forwarding,
- fences,
- atomics,
- cache coherency interactions.

## 10. Scheduler metadata

RTL8B feeds the actual live MSHR occupancy and configured capacity to the
existing scheduler metadata boundary.

This makes MSHR pressure real RTL telemetry rather than a synthetic placeholder.

`merge_ready_mask_i` remains zero in RTL8B. Before a `VLOADX` executes its
vector address-build phase, the scheduler does not yet have enough information
to predict exact line merge eligibility. A future predecode/address-prediction
mechanism may expose that safely; RTL8B does not guess.

## 11. Verification

### 11.1 Standalone load-MSHR bridge

The directed bridge test proves:

- one load spanning multiple lines allocates multiple MSHRs,
- reverse-order line responses reassemble the correct whole-wave value,
- no whole-wave completion occurs after only a partial line set,
- a same-line third wave merges while a two-entry table is full,
- merged waiters receive different word selections from the same returned line,
- three logical loads can generate only two physical line misses.

### 11.2 Live shared-engine core

The focused core test uses three resident waves and two MSHRs.

All three execute:

```text
VLOADX V3
VADD   V4, V3, V2
HALT
```

Wave 0 and wave 2 target different words of the same line. Wave 1 targets a
second line.

Required proof:

- three logical `VLOADX` operations create two physical line misses,
- the two-entry table becomes full,
- one same-line merge occurs,
- all three `V3` scoreboards remain reserved while waiting,
- a line response received while paused is buffered without retirement,
- wave 1 can finish `load -> dependent add -> halt` before the shared line for
  waves 0/2 returns,
- the later shared-line response fans out to both remaining waves,
- each context receives the correct word selections,
- all dependent adds observe the refilled values,
- all destination scoreboards drain at the end.

### 11.3 Integration edge test

Two waves merge on one line.

The test first sends a response with the correct entry ID but wrong line tag.
It must be rejected without consuming ownership.

A subsequent correctly tagged **fault** response must fan out to both merged
waiters, halt both load owners, release both destination scoreboards, and fully
drain MSHR ownership.

### 11.4 Store serialization

A dedicated integration test keeps a `VLOADX` MSHR live while a second wave
reaches `VSTOREX`. The store must generate no legacy backend request until the
load-MSHR bridge has completely drained. After that barrier clears, the store
request must carry the correct wave/context, addresses, lane mask, and store
data.

This test proves the conservative RTL8B ordering boundary is implemented, not
just documented.

### 11.5 Capacity elaboration sweep

The complete live production core is strict-linted with:

```text
MSHR_COUNT = 2, 4, 8, 16, 32
```

This catches width/elaboration mistakes that a standalone table-only capacity
test cannot detect.

### 11.6 Recursive regression

RTL8B's full gate runs RTL8A's complete gate afterward. RTL8A recursively runs
RTL7C and the existing historical verification chain.

## 12. What RTL8B does not claim

RTL8B is not a complete production memory hierarchy.

It does not yet provide:

- a cache implementation,
- cache-hit handling separate from miss handling,
- TLB/page translation,
- multiple memory-controller issue ports,
- return-bandwidth modeling,
- a store buffer,
- relaxed/strong memory ordering rules,
- fences or atomics,
- cache coherency,
- multi-port VRF refill,
- scheduler pre-issue merge prediction,
- adaptive-v1 hardware policy,
- a final MSHR count.

## 13. Next milestone

After RTL8B correctness is proven, the next useful step is to measure the live
memory path rather than immediately add more policy logic.

The likely follow-up should compare 2/4/8/16/32 entries under controlled
backend latency/bandwidth and quantify:

- achieved memory-level parallelism,
- allocator stalls,
- same-line merge rate,
- refill serialization cost,
- scheduler-visible pressure,
- area/storage/timing proxies.

Only then should A0 decide whether 16 or 32 is the better physical prototype
point and whether SIM17 adaptive-v1 should be implemented in scheduler RTL.
