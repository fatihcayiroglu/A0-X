# A0 RTL7B — Live Multi-Wave Execution

Status: implementation candidate pending the authoritative WSL Verilator gate.

## Purpose

RTL7A established resident architectural contexts and a deterministic LRR
scheduler. RTL7B connects those contexts to a **single shared live execution
path**.

This is the first milestone that may claim multi-wave RTL execution after its
gate passes. It does not create one `a0_wave_core` instance per wave.

## Architectural choice

The legacy `a0_wave_core` remains untouched as the historical compatibility
oracle. Rather than adding a very wide bulk context-load/save port to that
module, RTL7B introduces `a0_multi_wave_core`, reusing the already verified
execution building blocks:

- dependency classifier,
- RTL5B scoreboard semantics,
- lane sequencer,
- RTL6 operand collector behavior,
- banked vector-register-file behavior,
- RTL7A context file,
- RTL7A LRR scheduler.

This keeps old regression behavior stable while establishing the future
multi-wave top-level boundary.

## Allocation, pause, and ownership rules

RTL7B freezes the first safe physical VRF mapping:

```text
vrf_context_id == resident wave_id
```

A mismatched allocation is rejected. This prevents two live waves from
silently aliasing the same physical vector namespace. Dynamic VRF-context
allocation can be added later, but uniqueness must remain an invariant.

Allocation, release, and architectural debug-loader writes are accepted only
while `run_enable=0` and the shared vector engine is idle. If `run_enable` is
deasserted while a vector instruction is in flight, execution is **paused, not
aborted**: wave ownership, operand-collector state, lane-sequencer state,
scoreboard reservation, and scheduler cursor are preserved until resume.

Context release also clears only that wave's scoreboard bank as a defensive
teardown rule.

## Supported live subset

RTL7B intentionally limits the new top to:

- `SADD`, `SSUB`,
- `VADD`, `VSUB`, `VMUL`, `VAND`, `VOR`, `VXOR`,
- `VCMP_EQ`, `VCMP_LT`, `VCMP_LE`,
- `HALT`.

Global memory and structured divergence still run through the proven legacy
single-wave path. They will migrate only after context/vector ownership is
proven.

## Shared execution contract

Only one vector instruction owns the physical vector execution machinery at a
time. The scheduler rotates resident waves at **architectural instruction
retirement**.

A long vector instruction therefore keeps the shared lane sequencer until its
final physical beat retires. While that instruction is active, scheduler
selection is explicitly pinned to the owning wave so the retirement cursor
cannot advance from a different context. The next resident wave then becomes
eligible.

This is instruction-boundary interleaving, not yet latency-hiding issue from a
second wave while the vector unit is occupied.

## Wave-qualified vector register file

`a0_regfile_banked_contexted` extends the logical register address with a
resident VRF context:

```text
physical_index = vrf_context_id * VECTOR_REG_COUNT + logical_Vn
bank           = physical_index % BANK_COUNT
row            = physical_index / BANK_COUNT
```

The operand collector remains shared. `a0_vector_operand_path_contexted`
latches the request context and applies it to every source read in that
collector transaction.

This realizes the RTL7A ownership promise:

```text
{vrf_context_id, logical V register}
```

without duplicating an operand collector per resident wave.

## Wave-qualified scoreboard

`a0_wave_scoreboard_bank` contains one proven logical scoreboard state per
resident wave. Query/reserve/release events are routed by wave id.

Therefore `V3` busy in wave 0 does not make `V3` busy in wave 1.

The current shared execution engine permits only one vector instruction in
flight, but preserving wave-local dependency ownership now prevents a later
multi-issue scheduler from inheriting a global-register dependency bug.

## Scalar / predicate / EXEC state

The RTL7A context file remains the architectural owner of:

- PC,
- EXEC,
- scalar registers,
- vector predicates,
- scalar predicates,
- reconvergence metadata,
- halted/block state,
- VRF context id.

RTL7B adds a second scalar read port for `SADD/SSUB` and an independent debug
read view. The scheduler-selected context feeds execution directly; no bulk
context copy is required.

## Verification program

Two resident waves use the same logical register names but different data and
starting PCs.

Each executes:

```text
SADD
VCMP_LT P1, V1, V5
VADD.P1 V3, V1, V5
HALT
```

`V1` and `V5` deliberately map to the same bank (`reg % 4 == 1`) so the live
operand path must serialize a real bank conflict.

The two waves also use different:

- scalar source values,
- EXEC masks,
- initial P1 masks,
- vector source values,
- V3 sentinel values,
- starting PCs.

The directed test requires the architectural retirement order:

```text
wave0 pc0
wave1 pc8
wave0 pc1
wave1 pc9
wave0 pc2
wave1 pc10
wave0 pc3
wave1 pc11
```

and then checks:

- both waves halted independently,
- PC values remained independent,
- scalar results remained independent,
- generated P1 masks remained independent,
- EXEC/predicate masking touched only the expected vector lanes,
- same logical V3 in the two VRF contexts contains different correct data,
- bank-conflict telemetry was actually exercised,
- every wave-local vector/predicate scoreboard is empty after completion.

## Additional verification

The live two-wave program is not the only proof. RTL7B also adds:

### Context-qualified register-file directed test

Proves:

- identical logical `Vn` values remain isolated across contexts,
- cross-context reads still obey physical bank conflicts,
- lane-masked writes remain context-local,
- exact `{context, register, beat}` read/write collision uses merged bypass,
- a write to the same logical register in another context never cross-bypasses.

### Wave-qualified scoreboard directed test

Proves:

- wave 0 `V3` busy does not block wave 1 `V3`,
- wave 0 release cannot clear wave 1's reservation,
- predicate busy state is equally wave-local,
- explicit context teardown clears only the selected scoreboard bank.

### 10,000-transaction context-VRF differential

Four VRF contexts are initialized with context-coded data and exercised through
the real shared operand collector under randomized source enables, registers,
beats, backpressure, and bank conflicts. Every returned source payload is
checked against the Python expectation.

### Pause and ownership proof

The live core test pauses the first in-flight vector instruction for four
cycles and requires:

- `engine_busy` remains asserted,
- no retirement occurs,
- the LRR cursor does not move,
- execution resumes and reaches the same final architectural state.

It also deliberately attempts a mismatched wave/VRF-context allocation and
requires that no resident context be created.

## What RTL7B does not claim

RTL7B does not yet provide:

- overlapping memory requests from multiple waves,
- MSHR tags carrying wave id,
- scheduling another wave while the shared vector pipeline is occupied,
- per-wave pending-vector prefetch queues,
- live SPLIT/ELSE/JOIN in the new multi-wave top,
- adaptive-v1 scheduler hardware.

These remain follow-on integration work.

## Next milestone

After RTL7B passes, the next priority is memory/divergence integration rather
than another scheduler study. The multi-wave top must gain wave-tagged memory
ownership and structured-divergence state before the scheduler becomes more
aggressive.
