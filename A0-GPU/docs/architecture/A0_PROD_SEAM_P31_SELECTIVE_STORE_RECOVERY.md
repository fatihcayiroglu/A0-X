# PROD-SEAM-P31 — selective STORE recovery

This successor separates terminal STORE recovery from the persistent cache,
READ and WRITEBACK domain. Qualification is conditional: this document is not
a PASS receipt. The canonical `tests/run_prod_seam_p31.py` must complete its own
three parameter elaborations, six simulations, fresh unchanged P30 canonical
gate and final containment. A CLOSED checkpoint carries the actual receipt
and its raw evidence under `EVIDENCE/P31/CANONICAL`.

## Architecture and reset ownership

The new `a0_production_store_commit_selective_recovery_subsystem` composes
unchanged P24 directly with a new captured-commit frontend, unchanged standalone
P26 STORE completion and P27 timeout guards, and a persistent generation guard.
It does not reset the outer frozen P25/P26/P29/P30 hierarchy. All predecessors
remain unchanged and are separately regressed.

| State owner | Global cold reset | Local STORE rearm |
| --- | --- | --- |
| P24 cache, dirty lines, victim payload, line fabric, READ tags, WB attempts | Reset | Preserved |
| P26 STORE completion and P27 STORE timeout | Reset | Reset |
| P31 STORE generation, wrap barrier, rejected-status diagnostic | Reset | Preserved |
| P31 frontend | Reset | Explicit state transition; remaining aborted miss lanes discarded |
| READ accounting and stalled backend-command selection | Reset | Preserved |

Global cold reset is destructive and is not a dirty-cache flush. It requires
external quiescence; P31 claims no preservation across global reset.

The frontend round-robins commit ports, captures the complete lane mask and all
lane addresses/data, and holds one internal P24 commit through classification.
Each enabled lane must receive exactly one hit/miss classification. P24 has
finished and released its router before the first physical miss STORE is issued.
Miss lanes then complete sequentially through actual success statuses. A commit
gets `commit_ready` only after all its required work succeeds. A terminal failure
produces a stable, backpressured fault record and a separate one-cycle
`commit_abort` handshake. Neither abort nor recovery fabricates STORE success.

After fault acceptance, the failed source must withdraw its valid. A current
failed-STORE reuse-safe certificate, idle STORE attempt, idle P24 commit router,
and clean protocol diagnostics permit one REARM cycle. Only the two STORE guards
reset on its rising edge. The failed commit's remaining miss lanes are explicitly
cancelled; already completed cache-hit or earlier miss effects are not rolled
back. This is not an atomic multi-lane transaction.

REARM enters DRAIN. Already admitted READ/WB traffic resumes on real interfaces.
New client and commit admission stays fenced until actual read-delivery counts,
WB pending/active state and held line commands are drained. Resident dirty lines
do not prevent rearm or resumed admission and do not need artificial writeback.
Other commit ports may remain valid with stable payload throughout; they are
neither acknowledged nor aborted for the failed port.

## Identity, arbitration and cycle contract

Every accepted physical STORE command, including a retry, receives
`{generation, complete_local_attempt_id}`. The allocator advances on actual
selected backend acceptance, not ready for an unrelated line command. Local
rearm never rewinds it. A returned STORE status is forwarded only for a matching
live full ID with a live timeout, or the exact command accepted on that cycle.
Old SUCCESS, terminal failure and retryable failure cannot affect a fresh ID.

Generation exhaustion blocks new STORE commands while the final allocated
attempt can still finish. Reuse requires a current truthful all-generation
quiescence certificate after all historical statuses, including duplicates,
have become impossible. Early proof and failed-attempt-only reuse proof are not
substitutes. Raw status traffic blocks wrap-certificate acceptance. A finite
namespace cannot be safe against arbitrary historical responses without that
backend contract. P30's generation and stale-status tests remain fresh regressions.

The external interface stays a typed ready/valid command channel: READ has an
exact requester tag and line address, WRITEBACK has an exact slice/attempt ID
and full line payload, and STORE has full generation/attempt ID and word payload.
READ response and WB status channels bypass STORE recovery filtering entirely.
There is no claim of a physical VRAM controller or new cache coherence protocol.

Unheld STORE commands have priority over eligible line commands. Once either
source is offered with ready low, the source selection is retained until actual
acceptance. Each source retains its complete offered payload. In particular,
an already offered line command cannot disappear when L2_UPDATE becomes MISS.

| Coincident with actual REARM rising edge | Defined behavior |
| --- | --- |
| READ response | P24 accepts/routes the exact existing response; accounting continues |
| WB status | Persistent WB guard processes the exact current attempt; dirty victim data is retained until real success |
| Old STORE status | Not forwarded into locally resetting guards; rejected-status diagnostic persists |
| New STORE request | No ready/abort; remains pending until DRAIN finishes and normal selection resumes |
| New client request | Not admitted; can be accepted after the fence drops |
| Existing stalled line command | Remains offered and byte/identity stable; may accept normally |

## Directed qualification

The memory TB uses edge-based transaction ledgers, exact requester/attempt
comparisons, full-word payload checks, command-tuple stability monitoring,
bounded waits and an overall watchdog. Independent cases start with global cold
reset only after previous traffic is explicitly drained; recovery itself never
uses that reset.

- Dirty line + failed STORE + local recovery + cached read + later exact dirty
  writeback; the dirty word and every other word are compared byte-for-byte.
- Outstanding READ completing on the REARM edge, with exact client/local tag,
  address, data, no fault and exactly one delivery.
- Outstanding WB completing on the REARM edge; hidden replacement READ resumes
  through backend backpressure and returns to the original requester once.
- Simultaneous READ, WB and terminal STORE with pending second commit port;
  READ/WB/stale STORE status coincide with REARM and a fresh client is fenced.
- A new STORE first presented for the actual REARM edge remains pending and
  later succeeds exactly once, without recovery-generated completion.
- A dirty-victim WB held before STORE classification remains the exact offered
  tuple through L2_UPDATE to MISS, then real WB, STORE and replacement READ finish.
- STORE-only history tests cover multiple recoveries, same-cycle stale statuses,
  another pending commit port, retry payload stability, multi-lane success-only
  retirement and cancellation of only unissued miss lanes on abort.
- Generation widths 1/2/3 exercise truthful wrap and stale history. A one-cycle
  timeout test proves matching status priority, stale-status rejection, timeout
  provenance, and accepting-edge success/failure without a ghost live attempt.

The canonical runner rejects warning suppression at both outer and real inner
Verilator entrypoints, uses the bundled exact Verilator 5.050, generates/builds/
runs separately, and stops at the first failure. It retains raw return codes,
command logs, process-group lifecycle evidence, strict traces, source identities,
full checkpoint path/content/mode snapshots and raw-index containment. A fresh
unchanged P30 gate preserves its P27/P28/P29 chain; nested toolchain evidence is
verified as a separate stream, not falsely attributed to the parent wrapper.

## Bounds and evidence-based next work

P31 preserves state and enables post-STORE-rearm drainage. It does not guarantee
unconditional independent progress: new line commands remain blocked in MISS,
FAULT, ABORTED and REARM except an already held offer. DRAIN waits for every
admitted READ and active WB before admitting another commit. Thus an indefinitely
missing backend response, blocked fault consumer or absent generation certificate
can still hold admission. Safety proofs here assume stable source payloads,
truthful backend certificates and eventual service where progress is asserted.

The next bounded milestone must examine independent memory progress and
same-line ordering before relaxing these fences. Source evidence for that audit
is `line_service_allowed_o` in the new frontend and `memory_drain_idle` in the
composition, not a filename suggesting completion. Permitting unrelated READ/WB
progress cannot silently weaken pending STORE visibility or retry identity.

Full multi-cluster coherence, high-outstanding scalable fabric, physical VRAM,
complete SIMT/graphics/ray/matrix engines, compiler/runtime/driver integration,
formal liveness, synthesis/timing/PPA, FPGA and real workload performance remain
separate obligations. This memory-seam qualification is not a whole-GPU completion
percentage or a measured high-end ASIC performance claim.
