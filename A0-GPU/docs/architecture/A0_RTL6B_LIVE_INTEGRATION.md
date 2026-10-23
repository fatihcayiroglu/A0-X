# A0-RTL6B — Live Banked Vector Operand Integration

## Status

RTL6B is the live-integration phase following the standalone RTL6 banked
register-file and operand-collector foundation.

The milestone changes the **source of sequenced vector ALU/compare operands**
without yet deleting the legacy architectural `vector_regs` array.

The transition rule is:

> sequenced ALU/VCMP reads come only from the banked VRF; `vector_regs` remains
> a mirrored architectural/debug shadow and the legacy vector source for the
> still-blocking indexed-memory frontend.

This avoids a flag-day register-file rewrite while making the new physical
operand path observable in the real core.

---

## 1. Live datapath

```text
classifier / scoreboard
        |
        | issue + latched source-enable semantics
        v
  vector_issue_*
        |
        v
 lane sequencer beat N
        |
        | one request per visible beat
        v
 operand collector
        |
        +---- bank arbitration / retry ----+
        |                                  |
        v                                  v
     banked VRF <---------------------- 4 banks
        |
        | registered operand payload
        v
 vector beat ALU / VCMP
        |
        +--> banked VRF beat writeback (vector destination)
        |
        +--> vector_regs shadow mirror
        |
        `--> predicate_regs (VCMP destination)
```

The lane sequencer is no longer free-running while a vector instruction is
busy. It advances only when the current physical beat has a completed operand
set and the beat executes.

---

## 2. Dependency semantics

RTL6B latches the dependency classifier's enable-qualified metadata with the
issued instruction:

- vector source 0 enable,
- vector source 1 enable,
- vector source 2 enable,
- vector destination enable,
- predicate destination enable.

The operand collector consumes the latched source-enable bits.

The scoreboard release path consumes the latched destination-enable bits.
This removes the previous duplicated opcode lists that separately described
which vector and predicate destinations were released.

The classifier therefore remains the single live RTL authority for operand and
destination dependency semantics.

---

## 3. Beat ownership and collector handshake

The operand collector supports zero-bubble result-consume/request-accept
handoff. The live core must not re-submit the old beat on that edge.

RTL6B therefore adds a per-beat `vector_beat_request_sent` state bit:

1. lane sequencer exposes beat N;
2. core submits beat N once;
3. collector arbitrates bank conflicts and collects operands;
4. completed operand payload executes;
5. the lane sequencer advances and the sent bit clears;
6. beat N+1 may then submit.

This keeps beat identity explicit and prevents duplicate reads.

---

## 4. Register-file coherence during transition

### External/debug writes

When `run_enable=0`, the existing single-lane `vector_we` interface writes both:

- the architectural `vector_regs` shadow, and
- the matching lane inside the matching banked-VRF beat.

### Vector ALU writes

A sequenced vector ALU beat writes both:

- banked VRF through its one beat write port, and
- the matching lanes of `vector_regs` for architectural-state comparison.

### VLOADX writes

The current memory response interface returns a complete logical wave, while
the banked VRF has one physical-beat write port.

RTL6B therefore uses a coherence refill state:

1. successful VLOADX response updates `vector_regs` exactly as before;
2. issue remains stalled;
3. the loaded destination is copied into the banked VRF one physical beat per
   cycle using the original active-lane mask;
4. normal issue resumes only after the final beat is written.

This makes a `VLOADX -> dependent vector ALU` sequence correct even though the
legacy memory frontend has not yet been converted to the operand collector.

This refill is a **transition mechanism**, not the final non-blocking LSU.

---

## 5. Intentional non-goals

RTL6B does not yet:

- delete `vector_regs`;
- route VLOADX/VSTOREX address/data source collection through the banked VRF;
- implement multi-wave physical register allocation;
- implement register renaming;
- implement multiple collector slots;
- implement multi-ported or replicated banks;
- implement non-blocking memory or MSHRs;
- freeze the final bank mapping;
- freeze final register-file SRAM macro geometry.

The next architecture stages may replace the transition shadow/refill path once
all architectural vector consumers use the physical register subsystem.

---

## 6. Verification contract

RTL6B adds a live-core directed test that must prove:

1. **Banked source proof** — deliberately corrupt only the legacy shadow after
   initialization; a VADD result must still match the untouched banked VRF.
2. **Real same-bank conflict** — sources V1 and V5 map to the same bank with the
   four-bank baseline and must exercise conflict serialization.
3. **VLOADX refill coherence** — a loaded vector must be visible to an immediate
   dependent VADD through the banked path.
4. **Scoreboard release remains clean** — latched classifier destination enables
   release all reservations at completion.
5. **Historical regression** — RTL0 through RTL5E, RTL6 standalone directed and
   10,000-transaction operand differential tests, and Python regression all
   remain green.

A0-RTL6B is not complete until all five gates pass under Verilator.

## Refill ownership and issue isolation

A successful `VLOADX` response is first written to the architectural shadow and
then mirrored into the single-write-port banked VRF one physical beat per
cycle. `vrf_refill_pending` therefore owns the front end for the entire mirror
window. Dependency queries and all vector issue paths are explicitly disabled
during this state.

This is a correctness requirement, not only a performance choice. Without the
refill gate, the next vector instruction can produce `vector_issue_fire` while
the main sequential core is still executing the refill branch. The lane
sequencer and pending-buffer logic would observe the fire even though the core
cannot latch the matching issue metadata on that edge. RTL6B verification
requires `RTL6B_REFILL_ISSUE_ISOLATION=PASS` to prove that no query, issue, or
sequencer ownership escapes during refill.
