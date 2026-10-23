# A0-RTL6 — Banked Vector Register File and Operand Delivery Foundation

**Status:** IMPLEMENTED AS STANDALONE RTL — verification must be executed with Verilator 5.032+ in the project WSL environment before commit/tag.

## 1. Purpose

RTL5E closed the issue-queue dependency contract and restored verification integrity. The next scaling blocker is the current flat vector-register array inside `a0_wave_core.sv`.

RTL6 does **not** begin by rewriting the live core. It first establishes two independently verifiable primitives:

- `rtl/core/a0_regfile_banked.sv`
- `rtl/core/a0_operand_collector.sv`

The live `a0_wave_core.sv` remains unchanged in this phase. Integration is a separate gate after the standalone contracts pass.

## 2. Design goals

1. Preserve the existing `WAVE_SIZE` / `PHYSICAL_LANES` abstraction.
2. Avoid a physically unrealistic 3R1W monolithic vector register file.
3. Make bank conflicts explicit and measurable instead of hiding them in combinational fanout.
4. Allow all independent source reads to proceed together when they hit different banks.
5. Serialize same-bank sources without losing instruction state.
6. Define an exact read/write collision policy.
7. Keep register data storage SRAM-friendly by not resetting the data array.
8. Provide a clean path to a future multi-wave physical-register allocation scheme.

## 3. Reference configuration

| Parameter | RTL6 reference |
|---|---:|
| `VECTOR_REG_COUNT` | 64 |
| `WAVE_SIZE` | 32 |
| `PHYSICAL_LANES` | 8 |
| `BANK_COUNT` | 4 |
| logical source read ports | 3 |
| bank read capability | 1 read / cycle / bank |
| bank write capability | 1 write / cycle / bank |
| read latency | 1 cycle |
| write ports | 1 vector beat / cycle |

These are microarchitectural defaults, not ISA commitments. `WAVE_SIZE=32` is already architectural in the current A0 design; bank count and physical-lane width remain implementation parameters.

## 4. Physical register layout

For architectural register index `r`:

```text
bank = r % BANK_COUNT
row  = r / BANK_COUNT
```

A logical vector register is split into physical execution beats:

```text
BEAT_COUNT = ceil(WAVE_SIZE / PHYSICAL_LANES)
```

For the reference configuration:

```text
one architectural vector register
= 32 lanes × 32 bits
= 1024 bits
= 4 beats × 8 lanes × 32 bits
```

The storage primitive therefore holds:

```text
bank_mem[bank][row][beat] -> PHYSICAL_LANES × 32 bits
```

This matches the existing lane sequencer instead of forcing every register access to move an entire 1024-bit logical vector.

## 5. Read arbitration contract

`a0_regfile_banked` exposes three logical read request ports.

In one cycle:

- requests to different banks may all receive `read_ready=1`;
- requests to the same bank are granted in source-port order;
- denied valid requests assert `read_bank_conflict` and must be retried;
- every accepted request produces its response exactly one cycle later on the same logical response port.

The fixed port priority is safe for the RTL6 collector because a granted source immediately leaves the pending set. Therefore a three-source instruction with all sources in one bank completes the requests in bounded order rather than starving a low-priority source.

This is **not** the final multi-wave arbitration policy. Multi-wave operand arbitration will sit above or around this primitive and must have an explicit fairness contract.

## 6. Writeback contract

RTL6 has one vector-beat write port with a lane mask.

A bank is modeled as 1R1W, so read and write may occur in the same cycle even when they target the same bank.

If read and write target the exact same `{register, beat}` in one cycle:

- written lanes return the new write data;
- unmasked lanes return the previously stored data.

This is the RTL6 **write-through merged bypass** policy.

The policy is explicit because leaving inferred SRAM read-during-write behavior undefined would make the core dependent on FPGA/ASIC macro semantics.

## 7. Reset contract

Only control/response state is reset.

**Register data is intentionally not reset.**

Reason:

- a large vector register file should map to SRAM/register-file macros;
- bulk reset of every data bit prevents or damages SRAM inference on many targets;
- a newly allocated wave must initialize any architecturally required state through the normal write/dispatch path.

This differs from the current flat `a0_wave_core.sv` bring-up array, whose reset loop zeroes all vector registers. The integration milestone must preserve architectural differential tests by explicitly initializing test state rather than reintroducing a physical array reset.

## 8. Operand collector

`a0_operand_collector` owns one instruction beat at a time in RTL6.

For each of the three sources it tracks:

```text
pending  -> request has not yet won its bank
inflight -> bank accepted the request, response not returned yet
done     -> operand beat captured
```

Disabled sources begin in `done` state and return zero data.

The collector:

1. latches source registers and beat index;
2. presents unresolved sources to the banked RF;
3. automatically retries sources denied by bank conflicts;
4. captures one-cycle RF responses;
5. raises `result_valid` only when every enabled source is complete;
6. holds all result data stable under output backpressure;
7. permits a new request on the same edge that the previous result is consumed.

No opcode/dependency semantics live in the collector. The RTL5E classifier/scoreboard remains responsible for proving an instruction is dependency-safe before it enters operand delivery.

## 9. Why this architecture instead of a multiported flat RF

A 3-source vector operation at SIMD32 conceptually needs:

```text
3 reads × 32 lanes × 32 bits
+ writeback
```

Making that a true monolithic 3R1W memory scales poorly in area, wiring, and energy. Banking converts port pressure into an explicit scheduling problem:

```text
no bank conflict -> parallel operand fetch
bank conflict    -> bounded serialization
```

The performance cost is measurable through `bank_conflict_cycle`, which can later feed counters, compiler heuristics, register allocation, and scheduler policy studies.

## 10. Future multi-wave contract

RTL6 deliberately does **not** encode wave ID into the register-file interface.

The future multi-wave design should not hard-wire a giant array shaped as:

```text
wave × architectural register × lane
```

Instead, each wave context should own a physical-register allocation/base (or equivalent mapping), and logical `Vn` should be translated to a physical row before reaching the banked storage primitive.

That makes occupancy a real resource-allocation problem:

```text
more registers per wave -> fewer resident waves
fewer registers per wave -> more resident waves
```

which is essential for a competitive GPU architecture.

The RTL6 banking and beat structure remains reusable underneath that allocator.

## 11. Explicit non-goals of the standalone foundation

This phase does **not** yet implement:

- integration into `a0_wave_core.sv`;
- multiple resident wave contexts;
- physical register allocation / renaming;
- multi-wave bank arbitration;
- multiple simultaneous writeback clients;
- compiler bank-conflict-aware allocation;
- register-file cache / operand reuse cache;
- matrix-unit wide operand path;
- power/clock gating;
- FPGA/ASIC synthesis characterization.

None of these are frozen by RTL6 foundation.

## 12. Verification

### Directed banked-RF test

`tests/run_rtl6_regfile.py`

Required markers:

```text
RTL6_RF_RESET_CONTROL=PASS
RTL6_RF_BASIC_READ_WRITE=PASS
RTL6_RF_MASKED_WRITE=PASS
RTL6_RF_DIFFERENT_BANK_PARALLEL=PASS
RTL6_RF_SAME_BANK_CONFLICT=PASS
RTL6_RF_READ_AFTER_WRITE_BYPASS=PASS
RTL6_RF_BEAT_ISOLATION=PASS
RTL6_BANKED_REGFILE_TB=PASS
```

### Directed operand-collector integration test

`tests/run_rtl6_operand_collector.py`

Required markers:

```text
RTL6_COLLECTOR_RESET=PASS
RTL6_COLLECTOR_3SRC_NO_CONFLICT=PASS
RTL6_COLLECTOR_SAME_BANK_SERIALIZE=PASS
RTL6_COLLECTOR_DISABLED_SOURCE_ZERO=PASS
RTL6_COLLECTOR_BACKPRESSURE_STABLE=PASS
RTL6_COLLECTOR_ZERO_BUBBLE_HANDOFF=PASS
RTL6_OPERAND_COLLECTOR_TB=PASS
```

### Random differential stress

`tests/run_rtl6_operand_diff.py`

- initializes the real RTL banked RF through its write port;
- generates 10,000 randomized operand sets;
- covers 0/1/2/3-source combinations;
- randomizes register/beat selection;
- generates natural bank conflicts;
- applies randomized result backpressure;
- compares every returned source beat against a Python-generated architectural expectation.

Required marker:

```text
RTL6_OPERAND_DIFF=PASS seed=0xa061 transactions=10000
```

### Full gate

```text
python3 tests/run_rtl6_foundation_gate.py
```

The gate also reruns RTL0–RTL5E and the full Python regression. No RTL6 commit/tag is allowed unless this complete gate passes.

## 13. Integration sequence after foundation PASS

Only after the standalone foundation passes:

1. add an adapter boundary in `a0_wave_core.sv`;
2. migrate paused/debug register initialization through the new write port;
3. migrate vector source reads beat-by-beat through the collector;
4. migrate vector writeback through masked beat writeback;
5. preserve lane-sequencer semantics;
6. preserve RTL0–RTL5E differential results;
7. measure added bank-conflict cycles;
8. only then remove the old flat `vector_regs` storage.

The old array must not be deleted before the new path proves architectural equivalence.
