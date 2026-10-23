# A0 RTL7C — Wave-Tagged Multi-Wave Memory Execution

Status: **implementation candidate; commit requires the user-side Verilator
gate**.

RTL7C extends the live RTL7B shared multi-wave execution top with indexed
global-memory correctness. It is deliberately the bridge between:

```text
RTL7B
shared-engine multi-wave compute
        ↓
RTL7C
wave-tagged single-outstanding memory correctness
        ↓
future RTL8
multiple outstanding misses / MSHRs
```

RTL7C does **not** claim a non-blocking cache hierarchy or multiple
simultaneous backend transactions.

## Supported live multi-wave subset

The `a0_multi_wave_core` live path now supports:

- SADD
- SSUB
- VADD
- VSUB
- VMUL
- VAND
- VOR
- VXOR
- VCMP_EQ
- VCMP_LT
- VCMP_LE
- VLOADX
- VSTOREX
- HALT

Structured divergence is still outside the live multi-wave top.

## Addressing contract

RTL7C preserves the existing A0 provisional **word-addressed** indexed-memory
contract.

For each active lane:

```text
word_address =
    unsigned_32(scalar_base)
    + unsigned_32(vector_offset)
    + signed_imm24
```

The byte-address migration is intentionally not mixed into this milestone.

Every active address is validated before the one-cycle backend request pulse.
If any active lane is outside:

```text
0 <= word_address < GLOBAL_MEMORY_WORDS
```

the instruction faults without launching a partial request.

## Context-qualified sources

VLOADX:

```text
S[src0]          -> selected resident-wave scalar context
V[src1]          -> context-qualified banked VRF
P[pred], EXEC    -> selected resident-wave context
V[dst]           -> reserved in the selected wave scoreboard
```

VSTOREX:

```text
S[src0]          -> selected resident-wave scalar context
V[src1] offsets  -> context-qualified banked VRF
V[src2] data     -> context-qualified banked VRF
P[pred], EXEC    -> selected resident-wave context
```

Memory operands therefore no longer depend on a flat/shared logical vector
array.

## One shared physical beat engine

Indexed memory uses the same:

- resident-wave selector,
- dependency classifier,
- wave-qualified scoreboard,
- lane sequencer,
- operand collector,
- context-qualified banked VRF

as RTL7B vector compute.

VLOADX/VSTOREX are built one physical beat at a time. The final request is
launched only after all active lanes have been validated and their
address/store-data payload has been assembled.

## Single-outstanding backend contract

RTL7C intentionally exposes exactly one backend transaction at a time.

Request interface:

```text
mem_req_valid_o       one-cycle pulse
mem_req_write_o
mem_req_wave_o
mem_req_context_o
mem_req_lane_mask_o
mem_req_addr_o[lane]
mem_req_wdata_o[lane]
```

Response interface:

```text
mem_resp_valid_i
mem_resp_wave_i
mem_resp_context_i
mem_resp_fault_i
mem_resp_rdata_i[lane]
```

A response must echo both resident wave and VRF-context ownership tags.

An unsolicited or mismatched response:

- is ignored,
- does not consume the outstanding transaction,
- sets sticky `memory_tag_error_o`.

This is separated from `faulted_o`: a backend routing/protocol error is not
silently converted into an architectural memory fault.

The backend must not return a response in the same cycle as the request pulse.
Earliest legal response is the following cycle.

## Per-wave memory waiting

Memory request launch performs two distinct actions.

The owning architectural context is checkpointed as:

```text
PC = memory_instruction_PC + 1
memory_waiting = 1
```

and the RTL7A LRR cursor advances to another resident wave.

However, the memory instruction does not emit `retire_valid_o` at request
launch. Its architectural retirement event is deferred until backend
completion and, for VLOADX, context-VRF refill.

This distinction permits real latency hiding while preserving an explicit
memory completion event.

## Scheduling while memory is outstanding

The request owner is automatically removed from scheduler readiness by its
architectural `memory_waiting` bit.

Because the RTL7C backend is single-outstanding, another wave whose **current
instruction** is VLOADX/VSTOREX is transiently blocked while the backend is
occupied.

Compute waves remain schedulable.

To make that decision without head-of-line guessing, the RTL7A context file
now exposes a read-only vector of resident PCs:

```text
pc_by_wave[wave]
```

The live core classifies each current resident PC as memory/non-memory and
drives the existing RTL7A external blocker plus scheduler telemetry.

Therefore:

```text
wave 0: memory waiting
wave 1: compute ready
```

does not freeze the shared core.

## Scheduler metadata

RTL7C also gives the existing scheduler boundary real memory telemetry:

- current memory-ready wave mask,
- current non-memory-ready wave mask,
- memory-stalled mask,
- provisional memory-slot/MSHR occupancy = 0/1 across request, load refill, and final completion,
- provisional MSHR capacity = 1.

Same-line merge remains zero because RTL7C has no MSHR merge hardware yet.

LRR remains the reference hardware policy. SIM17 adaptive-v1 is still not
hardwired.

## VLOADX lifecycle

```text
classify + wave scoreboard reserve Vdst
        ↓
shared physical operand collection
        ↓
build all active word addresses
        ↓
fail-before-access validation
        ↓
wave-tagged request pulse
        ↓
owner context memory_waiting=1
        ↓
other waves may execute
        ↓
tag-checked response
        ↓
architectural vector shadow update
        ↓
serialized context-qualified VRF refill
        ↓
clear memory_waiting
        ↓
release owning wave Vdst scoreboard
        ↓
emit memory instruction retirement
```

The scoreboard reservation intentionally lives across backend latency and VRF
refill. A dependent instruction cannot observe a partially restored
destination.

## VSTOREX lifecycle

```text
collect context-qualified Voffset + Vdata
        ↓
build and validate request
        ↓
wave-tagged store pulse
        ↓
owner context memory_waiting=1
        ↓
other waves may execute
        ↓
tag-checked store completion
        ↓
clear memory_waiting
        ↓
emit store retirement
```

VSTOREX has no destination scoreboard reservation, but per-wave
`memory_waiting` prevents its architectural stream from running ahead of the
completion.

## Response/refill arbitration

RTL7C still has one physical VRF write port.

If a load response arrives while another wave already owns the vector engine:

1. response data is buffered,
2. that already-running vector instruction is allowed to finish,
3. new issue is blocked briefly,
4. VLOADX refill writes one physical beat per cycle,
5. memory completion clears the owner context.

This avoids two writers silently contending for the same physical VRF port.

## Pause semantics

`run_enable=0` preserves:

- in-flight vector execution,
- backend memory ownership,
- response ownership tags,
- buffered load response,
- refill progress,
- scoreboard reservation,
- architectural memory_waiting.

A correctly tagged backend response may arrive while execution is paused. It
is captured, but VRF refill and architectural retirement wait until
`run_enable` resumes.

Maintenance operations (allocation, release, program writes, debug
architectural writes) are accepted only when both compute and memory
ownership are quiescent.

## All-masked memory operation

If EXEC/predicate filtering leaves no active lanes:

- no backend request is generated,
- VLOADX reservation is released,
- PC advances normally,
- the instruction retires as an architectural no-op.

## Fault behavior

### Address fault

If any active lane is out of range:

- no backend request is generated,
- the wave is halted,
- held scoreboard state is released,
- `faulted_o` is asserted,
- the faulting memory instruction emits its terminal retirement event.

### Backend fault

For a correctly tagged response with `mem_resp_fault_i=1`:

- no load refill occurs,
- the owning wave is halted,
- memory_waiting is cleared,
- load scoreboard ownership is released,
- `faulted_o` is asserted,
- the memory instruction emits its completion retirement.

## Verification

### RTL7C live memory test

Two resident waves intentionally reuse logical register names while owning
independent physical contexts.

Wave 0:

```text
VLOADX V3, S0, V1, pred=P1
VADD   V4, V3, V2
HALT
```

Wave 1:

```text
VADD
SADD
VSTOREX S0, V1, V2, pred=P1
HALT
```

The load response is delayed.

Required proof:

- wave-0 request carries wave/context 0,
- wave 0 becomes memory_waiting,
- wave-1 VADD and SADD retire before the load response,
- a wrong response tag is rejected without consuming ownership,
- the correct response can be captured during `run_enable=0`,
- VLOADX refill is context-qualified,
- V3 scoreboard ownership persists through latency/refill,
- dependent wave-0 VADD uses the refilled data,
- wave-1 store carries wave/context 1,
- store addresses/data come from context 1 VRF,
- wave-0 HALT retires while the store response is delayed,
- both waves finish with isolated vector/scalar state.

### RTL7C edge test

Separately proves:

- all-masked VLOADX generates no backend access,
- out-of-range active lane faults before any request,
- correctly tagged backend fault completes/halts cleanly.

### Regression closure

`tests/run_rtl7c_gate.py` requires:

1. Python compile,
2. warning-fatal production Verilator lint,
3. live two-wave load/store latency-hiding test,
4. memory edge/fault test,
5. full RTL7B gate,
6. therefore recursively RTL7A, SIM17, SIM16, SIM15, RTL6B, RTL6 and all
   historical RTL/Python differential regressions,
7. `git diff --check`.

Commit permission requires:

```text
RTL7C_GATE=PASS
RTL7C_COMMIT_ALLOWED=YES
```

## What RTL7C does not claim

RTL7C does not yet provide:

- multiple simultaneous backend memory transactions,
- MSHR allocation,
- same-line miss merge,
- out-of-order memory returns,
- cache-bank/channel/DRAM scheduling,
- TLBs,
- store buffer,
- atomics,
- byte-address migration,
- adaptive-v1 hardware scheduling,
- live multi-wave SPLIT/ELSE/JOIN.

The next memory milestone can now introduce MSHRs on top of a proven
wave-tagged correctness boundary instead of combining both problems at once.
