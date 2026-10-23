# A0 RTL7A — Resident Wave Context + Scheduler Foundation

Status: **foundation milestone**.

RTL7A establishes the first synthesizable multi-wave control boundary in A0.
It does **not** yet claim that `a0_wave_core` executes multiple waves.
That integration is explicitly RTL7B.

## Why RTL7A exists

Before sharing the existing single-wave execution machinery across multiple
resident waves, A0 needs three contracts that are independently testable:

1. resident architectural context storage,
2. deterministic wave selection/fairness,
3. a selected-context interface that later execution RTL can consume.

Building these first avoids mixing context-corruption bugs with vector-pipeline
or memory-pipeline bugs.

## Resident context state

`rtl/scheduler/a0_wave_context_file.sv` stores per resident wave:

- valid / allocated state,
- PC,
- EXEC mask,
- reconvergence stack pointer,
- halted state,
- generic blocked state,
- memory-waiting state,
- barrier-waiting state,
- scalar registers,
- vector predicate registers,
- scalar predicate registers,
- structured-divergence stack entries,
- `vrf_context_id`.

The large scalar/predicate/reconvergence payload arrays are intentionally not
reset. Control state is reset. This follows the same SRAM-friendly principle
already used by the banked vector register file: launch/restore initializes
architectural payload before use.

### VRF ownership boundary

RTL7A does not enlarge `a0_regfile_banked`.

Instead every resident context owns a `vrf_context_id`. RTL7B will use the
logical mapping:

```text
physical vector namespace = {vrf_context_id, logical V register}
```

This is the boundary that prevents the current single-wave logical V0..V63
namespace from becoming a dead end.

## Ready contract

A resident wave is architecturally ready only when all are true:

```text
valid
&& !halted
&& !blocked
&& !memory_waiting
&& !barrier_waiting
```

`a0_multi_wave_frontend` then applies a separate `external_block_mask_i`.
That distinction is intentional:

- context blockers are architectural state that must survive scheduling,
- external blockers are transient execution/resource conditions.

## Reference scheduler

`rtl/scheduler/a0_wave_scheduler.sv` implements deterministic loose
round-robin (LRR).

Properties:

- scans from an explicit round-robin cursor,
- skips unready waves,
- cursor advances only on `grant_fire_i`,
- backpressure leaves the selected wave stable,
- an external policy override is accepted only for a ready wave,
- invalid or unready override falls back to LRR.

The override boundary is deliberately separate from the reference policy.
SIM17 adaptive-v1 is **not** hardwired into RTL7A.

## SIM17 policy metadata boundary

The scheduler accepts / exposes:

- MSHR occupancy,
- MSHR capacity,
- >=50% MSHR pressure indication,
- ready memory-wave mask,
- ready non-memory-wave mask,
- memory-stalled-wave mask,
- same-line merge-ready mask,
- ready / stalled / merge counts.

This is enough to connect a later RTL8 policy implementation without changing
the correctness reference scheduler.

## Selected-context frontend

`rtl/scheduler/a0_multi_wave_frontend.sv` connects the context file and
scheduler.

The grant immediately selects the matching architectural context view:

- PC,
- EXEC,
- reconvergence state,
- scalar data,
- predicate data,
- VRF context ownership token.

RTL7B will connect this selected-context view to the existing execution
engine and checkpoint retired state back into the context file.

## Verification

### Directed context test

Proves:

- control reset,
- explicit allocation,
- independent state in multiple resident waves,
- scalar/predicate isolation,
- reconvergence-stack isolation,
- VRF ownership token isolation,
- ready-mask behavior for blocked/memory/barrier/halt,
- release/reallocation.

### Directed scheduler test

Proves:

- no cursor movement under backpressure,
- LRR fairness,
- blocked-wave skipping,
- policy override acceptance,
- override fallback,
- pressure telemetry,
- empty-ready-set behavior.

### Frontend integration test

Proves:

- scheduler grant selects the matching context,
- external and architectural blocking are distinct,
- policy override cannot escape readiness,
- grant consumption advances the LRR cursor,
- SIM17 pressure/merge metadata is visible,
- released contexts disappear from selection.

### 10,000-cycle Python ↔ RTL differential

The randomized scheduler differential uses **3 resident waves** intentionally.

Three waves require a 2-bit wave ID, leaving ID `3` invalid. This exercises:

- non-power-of-two wrap behavior,
- invalid override IDs,
- random ready masks,
- random memory/non-memory/stalled masks,
- random merge masks,
- MSHR pressure values,
- random backpressure / grant consumption.

The Python model and RTL must match cycle-for-cycle.

## What RTL7A does not claim

RTL7A does not yet provide:

- multi-wave instruction execution in `a0_wave_core`,
- physical vector-register capacity for multiple contexts,
- per-wave vector scoreboard state in the live core,
- per-wave pending vector instruction state,
- multi-wave memory request tags,
- barrier workgroup membership,
- adaptive-v1 hardware policy.

Those are integration work, not hidden inside this foundation milestone.

## Next: RTL7B

RTL7B should:

1. extract/share the current single-wave execution state behind the selected
   context interface,
2. checkpoint PC/EXEC/reconvergence/scalar/predicate state per wave,
3. extend vector RF physical addressing with `vrf_context_id`,
4. make vector/predicate scoreboard ownership wave-qualified,
5. prove two or more resident waves can interleave execution without state
   leakage,
6. keep LRR as the reference selector while leaving the RTL8 policy hook open.

Only after that proof should A0 claim live multi-wave RTL execution.
