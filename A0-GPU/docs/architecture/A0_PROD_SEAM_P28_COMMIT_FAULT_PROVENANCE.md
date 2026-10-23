# PROD-SEAM-P28 — exact commit fault / abort provenance

P28 freezes canonical P27 and adds the architectural identity boundary that must exist before a terminal `STORE_WORD` failure can be recovered safely.

## Commit-front contract

`a0_production_store_commit_fault_provenance_subsystem` arbitrates the external production commit ports round-robin, captures one exact source transaction `{port_id, lane_mask, word_addr[], wdata[]}`, and feeds that immutable transaction into frozen P27 through a single internal commit port. The external source must hold valid and payload stable until either normal success or the separate fault-abort handshake.

Normal `commit_ready_o` is **success-only**. P28 never converts P27 terminal store failure, timeout, retry exhaustion, or backend failure into normal commit ready.

If frozen P27 reaches terminal store failure, P28 retains the exact originating commit-port identity and captured payload in a backpressure-safe fault record. The record also distinguishes whether P27 observed a STORE_WORD timeout and retains the final store retry count. `commit_fault_valid_o` remains asserted with stable payload until `commit_fault_ready_i` handshakes.

That fault handshake produces a one-cycle `commit_abort_o` only for the exact originating source port. It is a separate architectural squash/abort completion and is never simultaneous with normal success ready. After abort acknowledgement the composed subsystem enters an explicit `recovery_required_o` halt state; frozen P27 remains fail-closed and its captured source is retained internally until reset/recovery. P28 deliberately does not pretend the backend is reuse-safe or automatically restart P27.

## Proven behavior

Directed qualification proves:

- two simultaneous successful commit ports are selected round-robin and preserve exact source address/data identity;
- normal success uses only the selected port's `commit_ready_o` and emits no abort/fault;
- timeout failure never pulses normal success ready;
- fault `{port_id,lane_mask,address,data}` remains stable under fault backpressure;
- timeout provenance is explicit and distinct from a genuine backend non-retryable terminal failure;
- fault acknowledgement produces exactly one source-specific `commit_abort_o` and no normal ready;
- post-abort state is explicitly recovery-required;
- no transaction produces both success and abort/fault completion;
- frozen P27 identities and repository containment remain unchanged.

## Deliberate bounds

P28 establishes fault/squash provenance only. It does not yet perform backend recovery-safe joining, reset/restart of frozen P27, automatic replay, physical VRAM/DRAM control, ownership/snoops, atomics, byte masks, globally atomic multi-lane stores, or a complete global memory-ordering model.
