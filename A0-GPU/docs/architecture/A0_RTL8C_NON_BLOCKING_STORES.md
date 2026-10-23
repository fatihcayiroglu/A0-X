# A0 RTL8C — Non-Blocking Stores and Conflict-Aware Memory Ordering

## Status

RTL8C introduces the first live buffered-store path in the A0 multi-wave core.
`VSTOREX` is no longer tied directly to the single-outstanding legacy backend:
whole-wave stores may queue while the physical backend remains single-transaction.

RTL8C-5B2 extends conflict-aware ordering with fault-safe store-to-load
forwarding from the youngest older exact, unambiguous queued or physical source.
Same-line conflicts without a safe exact source remain conservative. Fences,
atomics, and coherency remain out of scope.

## Store pipeline

```text
VSTOREX
  -> vector execution / indexed address + data build
  -> whole-wave a0_store_queue enqueue
  -> wave remains memory_waiting
  -> FIFO head waits for backend idle + older MSHR loads to drain
  -> one physical tagged legacy store request
  -> backend response
  -> mem_complete_pending_q
  -> retirement of original VSTOREX PC
```

Queue insertion is not architectural retirement.

## Queue entry

Each queue entry owns:

- wave id;
- context id;
- active lane mask;
- per-lane word address;
- per-lane write data.

The queue is strict FIFO and permits at most one live queued store per resident
wave. Backend completion is owned by the core, not by the queue.

## Pre-issue wave versus enqueue wave

These identities are intentionally different.

Before vector issue, store readiness is evaluated for:

```text
frontend_grant_wave
```

The selected store is ready only if the queue has capacity and that selected
wave does not already own a queued store.

After execution reaches release, the real queue payload is owned by:

```text
exec_wave_q
exec_vrf_context_q
```

Therefore `enqueue_wave_i` remains `exec_wave_q`. Using `exec_wave_q` for
pre-issue readiness would incorrectly qualify the next selected wave against a
previous execution owner.

## Architectural ownership

At enqueue the core preserves per-wave:

- original store PC;
- resume PC;
- execution mask;
- reconvergence-stack pointer.

When the FIFO head physically launches, those fields move into `mem_owner_*`.
The physical backend response retires the original store instruction PC and
advances the context via `mem_owner_resume_pc_q`.

## Conservative ordering rules

1. A store may enqueue while older MSHR-backed loads are still live.
2. FIFO drain normally waits for live MSHR loads; RTL8C-5B1 permits only an
   age-safe head needed to resolve a live provisional forwarding dependency.
3. A queued store blocks only lanes whose line conflict is not resolved by the
   selected exact, age-qualified, unambiguous forwarding source.
4. RTL8C-5B2 applies the same rule to a physical pending store, except that new
   physical-source capture is suppressed while that store response resolves.
5. Additional stores may enqueue while capacity remains.
6. Stores reach the physical backend strictly FIFO.
7. The legacy physical backend remains single-outstanding.

The resulting supported state includes:

```text
1 physical store + N queued stores
```

without creating multiple physical legacy transactions.

## Pause / resume

Queue drain requires `run_enable`, so pause preserves queued entries.

A response to an already-launched physical store is still captured while paused.
The response clears physical ownership into `mem_complete_pending_q`, but
architectural retirement waits until `run_enable` returns. The next queued store
also cannot drain while paused.

## Response tags and faults

A stale or misrouted response raises the tag-error indication without consuming
the current physical owner.

A correctly tagged backend fault completes only the owning store. The faulting
wave retires through the delayed memory-completion path, and later FIFO stores
may continue after that completion is serialized.

## Backpressure

Store pre-issue blocks when:

- the queue is full; or
- the selected wave already owns a queued store.

Physical drain blocks when:

- execution is paused;
- the legacy backend is unavailable; or
- older live MSHR ownership remains.

A full queue intentionally does not implement same-cycle dequeue+enqueue
replacement. Full applies enqueue backpressure even if the head can drain.

## Parameterization

`STORE_QUEUE_DEPTH` is verified at:

```text
1, 2, 3, 4, 5, 8, 16
```

The sweep is both production-core lint/elaboration and behavioral queue testing.
Non-power-of-two depths are included. Pointer advance explicitly wraps at
`STORE_QUEUE_DEPTH - 1`, so depth 3 and depth 5 do not rely on binary overflow.

## Conflict probe

The store queue exposes two dependency views:

- exact queued word-address/source metadata, consumed by RTL8C-5 forwarding;
- cache-line conflict using the same line geometry as the MSHR load path.

RTL8C-4 uses cache-line conflicts for ordering. A younger MSHR-backed `VLOADX`
first completes address generation and then compares its active-lane address
set against both:

1. all stores still resident in the store queue; and
2. the already-drained physical store represented by
   `mem_pending_valid_q`, `mem_pending_load_q == 0`, and the explicit
   `mem_owner_store_addr_q` snapshot.

A load may enter the RTL8B MSHR bridge when it has no line conflict or when
RTL8C-5 resolves every conflicting lane with the selected exact, age-qualified,
unambiguous source. Such forwarded lanes remain provisional. Any remaining
unresolved line conflict moves the load into the one-entry post-address
order-wait slot until replay becomes safe.

Using the queue probe alone remains incorrect because a store stops being
visible to the queue probe as soon as it drains into the physical backend.
## Verification

`tests/run_rtl8c_store_queue.py` verifies reset, metadata/data capture,
one-store-per-wave protection, full backpressure, conflict probing, FIFO order,
wave reuse, and final drain.

`tests/run_rtl8c_store_queue_capacity.py` behaviorally sweeps depths
1,2,3,4,5,8,16 and checks capacity, FIFO data/ownership, pointer wrap,
simultaneous enqueue/drain, and the intentional depth-1/full no-replacement
policy.

`tests/run_rtl8c_multi_store.py` verifies:

- live older load + buffered stores;
- queue-full backpressure;
- pause preservation;
- enqueue/request launch does not retire a store;
- one physical plus two queued stores;
- one physical store outstanding;
- response tag guard;
- physical store response capture while paused;
- FIFO store issue;
- fault followed by later FIFO progress;
- original store-PC retirement order;
- final queue/backend/MSHR drain.

`tests/run_rtl8c_load_bypass.py` verifies queued and physical provisional
forwarding, fault fallback, youngest-source selection, response-cycle suppression,
non-conflicting bypass, same-line holds, pause-safe order-wait preservation, and
replay into the existing MSHR load path.

`tests/run_rtl8b_gate.py` is rerun by the RTL8C gate to preserve the previous
load-MSHR and legacy regression chain.

## Closure gate

Run:

```bash
python3 tests/run_rtl8c_gate.py
```

A successful closure ends with:

```text
RTL8C_GIT_DIFF_CHECK=PASS
RTL8C_GATE=PASS
RTL8C_COMMIT_ALLOWED=YES
```

## Deliberate non-goals

RTL8C does not yet provide:

- same-cycle capture from a physical store whose backend response is already resolving;
- partial store merging / write combining;
- memory fences;
- atomics;
- coherency;
- cache/coalescing;
- VM/TLB ordering;
- memory dependence prediction.

RTL8C-4 implements the first ordering relaxation by combining queued-store
cache-line conflicts with explicit physical-store ownership. RTL8C-5A adds a
reset-domain monotonic store sequence, exclusive load age boundaries, and
youngest-older exact-word source resolution without changing load dataflow.
RTL8C-5B1 consumes the queued-source subset for fault-safe partial forwarding.
RTL8C-5B2 extends the same provisional/fault-replay mechanism to the combined
5A youngest-older source, including a physical pending store when safe.


---

## RTL8C-4 — Conflict-Aware Safe Load Bypass

RTL8C-4 moves the dependency decision to the first point where a VLOADX owns its
complete active-lane word-address set.

```text
complete load address set
        |
        +-- queued-store line conflict
        |
        +-- physical-store line conflict
        |
        v
combined conflict
   |          |
  yes         no
   |           |
order wait   RTL8B MSHR bridge
```

A conflicting load does not keep `exec_active_q` asserted. Its architectural and
address state is copied into one `load_order_wait_q` slot, the wave remains
`memory_waiting`, the scoreboard reservation stays live, and the shared vector
engine is released. This prevents the deadlock where an older MSHR completion
needs an idle engine while the conflicting younger load waits for a store that
itself cannot drain until older MSHRs disappear.

While the wait slot is occupied, a second VLOADX is blocked. Stores and
non-memory work remain schedulable.

When both queued and physical line conflicts disappear, the held transaction is
accepted into the existing RTL8B whole-wave load bridge. MSHR table capacity is
handled internally by that bridge/table allocator; it does not reject the
whole-wave enqueue.

Physical store conflict checking and RTL8C-5B2 forwarding use explicit
`mem_owner_store_addr_q` and `mem_owner_store_wdata_q` snapshots rather than
request-output retention.

RTL8C-4's conservative cache-line hold remains for same-line/different-word or
otherwise unresolved accesses; RTL8C-5 uses exact-word source metadata only when
the selected source is age-qualified and unambiguous.

Directed verification:

```text
tests/rtl/a0_multi_wave_core_rtl8c_load_bypass_tb.sv
tests/run_rtl8c_load_bypass.py
```

---

## RTL8C-5A — Store Age and Forwarding-Source Identity

RTL8C-5A is a metadata foundation only. It does **not** forward store data into
a load and therefore does not change architectural load results.

Every accepted VSTOREX receives a reset-domain monotonic `STORE_SEQ_W` sequence
identity when it enters the store queue. The identity is stored with the queue
entry and copied into `mem_owner_store_seq_q` when the FIFO head becomes the
physical store.

A VLOADX uses an exclusive sequence boundary:

```text
store_seq < load_boundary   -> older candidate
store_seq >= load_boundary  -> younger/equal, ignore as a forwarding source
```

For a current load the boundary is `store_seq_next_q`. If RTL8C-4 moves the load
into the order-wait slot, that boundary is snapshotted in
`load_order_wait_store_seq_boundary_q`. Stores that issue later may remain
conservative ordering conflicts, but they cannot become forwarding sources for
the already-held load.

The queue resolves exact-word candidates by sequence identity rather than raw
array slot number and reports the **youngest older** source for each load lane.
The core combines that result with the physical pending store using the same
sequence comparison.

If multiple active lanes of one store target the same word, the source is marked
ambiguous. Backend lane-application order is not architecturally defined yet, so
RTL8C-5A deliberately refuses to treat one lane's payload as authoritative.

Store sequence wrap is outside the current bounded reset-domain verification
horizon; the default width is 64 bits.

Directed verification:

```text
tests/rtl/a0_store_queue_rtl8c5_age_tb.sv
tests/run_rtl8c5_age.py
```

The RTL8C gate requires the age/source foundation before rerunning multi-store,
safe-bypass, and the complete RTL8B regression chain.


## RTL8C-5B1 — Fault-safe queued-store forwarding

RTL8C-5B1 consumes RTL8C-5A age/source metadata for the first architectural
store-to-load forwarding path. Its scope is deliberately limited to **queued**
stores. A load lane may consume a queued value provisionally only when the 5A
source is exact, older than the load boundary, and unambiguous.

Forwarded data is not immediately architectural. The wave-load MSHR bridge
keeps per-lane `{source_seq, provisional_data}` dependency state. Forwarded
lanes are removed from the initial backend-pending mask, while non-forwarded
lanes continue through the normal line-MSHR path. A successful response for the
matching source sequence marks the provisional lane complete. A faulting source
response discards the provisional value and returns the lane to the ordinary
MSHR pending mask so the load reads the pre-store memory value.

Whole-wave completion still requires all architectural lanes to complete and
all forwarding dependencies to resolve, so provisional data cannot reach VRF
refill early.

Queue progress is dependency-qualified: while the load bridge is active, the
store FIFO may drain only when a live forwarding dependency exists and the FIFO
head sequence is older than every MSHR-active load's captured store-sequence
boundary. This prevents the dependency override from passing stores that are
younger than an already-active MSHR load. Held order-wait loads continue to use
RTL8C-4 conservative conflict drain/replay, including later stores that remain
conservative ordering conflicts.

Within the RTL8C-5B1 scope, physical-store forwarding was intentionally
deferred to RTL8C-5B2. A store that was already physical when the load was
probed therefore kept the proven RTL8C-4 line-conflict hold/replay behavior.

As in RTL8C-5A, 64-bit sequence wrap remains outside the bounded reset-domain
verification horizon.


## RTL8C-5B2 — Fault-safe physical-store forwarding

RTL8C-5B2 extends the 5B1 provisional forwarding contract to a store that has
already drained from the FIFO into the single physical backend transaction. The
physical source value comes from the preserved `mem_owner_store_{seq,addr,wdata}`
metadata, not from the one-cycle backend request outputs.

The RTL8C-5A combined source resolver remains authoritative: for each load lane,
queued and physical exact-word candidates are compared by sequence and the
**youngest older** unambiguous source wins. RTL8C-5B2 additionally records the
origin of that winning source. This origin bit is core-local metadata; the MSHR
bridge continues to consume the generic `{forward_mask, source_seq, data}`
contract introduced in 5B1.

A winning physical source is forwarding-safe only while its backend response is
not resolving in the same cycle as the load probe. A correctly tagged physical
response is a one-cycle resolve event. Capturing a new physical dependency on
that same edge would install bridge wait state after the resolve scan has already
observed the old state. RTL8C-5B2 therefore suppresses only the physical-selected
lane on `store_response_resolve_fire`; the load retains the conservative
line-conflict hold and replays after the physical owner clears. A younger queued
source remains forwardable on that cycle because its future resolve event has
not occurred.

Physical forwarded lanes use the existing 5B1 dependency state machine:

- source success clears forward-wait and commits provisional data;
- source fault clears the provisional value and re-arms the lane in the normal
  MSHR pending mask;
- whole-wave completion still requires no backend-pending lanes, no unresolved
  forwarding dependencies, and complete coverage of the expected lane mask;
- duplicate active physical store lanes targeting the same load word remain
  ambiguous and are never forwarded.

The legacy physical backend stays single-outstanding. RTL8C-5B2 changes only
load data-source selection and conflict resolution; it does not create a second
physical store transaction or relax FIFO store launch order.
