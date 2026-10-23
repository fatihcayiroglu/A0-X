# PROD-SEAM-P30 — generation-qualified STORE_WORD identity

This document defines the P30 implementation and qualification contract.
Completion is established by actual canonical evidence and verified checkpoint
packaging, not by this document's existence. In a closed checkpoint, consult
`EVIDENCE/P30/CANONICAL/p30-receipt.json` and root `CHECKPOINT-STATE.md`.
The frozen P29 implementation remains unchanged.

## Predecessor evidence and the concrete gap

The frozen P29 canonical runner reports `PROD_SEAM_P29_GATE=PASS` in
`/tmp/a0_p30_p29_ddlw75nd/002_p29_canonical.log`. Strict verification for that
validation directory records six outer and 24 inner calls in total; one outer
and four inner calls belong to helper qualification, leaving five outer and 20
inner calls attributable to the canonical runner. The canonical P28 predecessor
check uses its frozen receipt, rather than a new P28 simulation.

A separate actual reproduction, recorded in
`/tmp/a0_p30_repro_8bce71gt/005_p29_repro_sim.log`, first completes a STORE_WORD
through a real accepting commit edge, then fails the next word and performs the
P29 recovery join. The log records the successful prefix handshake, then
`P29_REPRO_IDENTITIES failed=2 fresh=2`, followed by the explicit
`P29_REPRO_FIRST_RECOVERY_ID_COLLISION` failure.

P26 increments its local write ID after success. P29 resets that ID to zero and
XORs one epoch bit into the existing ID field. Consequently the failed second
word and first word after recovery can have the same backend-visible ID on the
first recovery. This is a missing case in P29's bounded qualification; the P29
canonical PASS does not establish absence of this collision.

P30 composes the unchanged P29 module inside
`a0_production_store_commit_generation_subsystem.sv` and qualifies its entire
opaque STORE attempt ID with a separate prefix.

## Identity allocation and status handling

The external STORE identity is
`{generation, whole_P29_STORE_attempt_id}`. Its width is
`STORE_GENERATION_W + P29_STORE_ATTEMPT_ID_W`, where the latter preserves
`STORE_WRITE_ID_W + STORE_RETRY_W`. READ tags and WRITEBACK attempt IDs retain
their existing widths and values.

The prefix advances on every accepted physical STORE command, including retries
and subsequent words of one commit. It survives P29's local rearm. This also
separates ordinary P26 local write-ID reuse, provided the outer prefix has not
been reused without the wrap proof described below. Merely advancing a recovery
counter would leave ordinary local write-ID wrap uncovered.

`store_generation_next_o` exposes the next prefix to allocate. The prefix and
opaque command ID remain stable while a STORE command is backpressured. The
wrapper gates both external STORE valid and P29's STORE ready when allocation is
blocked, so frozen P27 cannot start a timeout for an unaccepted command.

The wrapper retains a separate accepted full identity. It forwards real status
only when that full identity matches an accepted attempt whose P27 timeout
window is still live, or the status matches a STORE command actually accepted
in the same cycle. Matching command and status in one cycle allocate and retire
the attempt together. A status for an older generation, an older retry, an
unaccepted command, or a timed-out attempt cannot be relabeled as a fresh result.

Matching success, retryable failure, terminal failure, and P27's local timeout
retire the outer live attempt. A current matching status reaches frozen P27 on
the deadline cycle, preserving its real-status priority over timeout. Rejected
status does not release the source or restart the live timer. Architectural
commit ready remains success-only; abort remains a separate source-specific
completion inherited from P28/P29.

## Finite prefix wrap

`STORE_GENERATION_W` defaults to eight and supports widths of one or greater.
Width one is safe under this contract, but exhausts its two prefixes quickly.
No finite width alone establishes permanent uniqueness.

After the maximum prefix is allocated, the next-prefix value becomes zero and
`store_generation_wrap_pending_o` blocks the next STORE issue. The final
pre-wrap attempt retains its full identity and can still complete. The barrier
does not disable its status path.

Prefix reuse requires `backend_store_all_generations_quiescent_i` while wrapping
is pending, no outer attempt or P27 timeout is live, and no STORE status is
present that cycle. A proof offered before wrapping is pending is not remembered.
Issue can resume after proof acceptance, on a subsequent cycle.

This input is a truthful backend certificate: every historical STORE status
that could alias a reused prefix has drained and cannot subsequently arrive,
including delayed or buffered duplicates. It is stronger than failed-attempt
reuse-safe and stronger than observing one quiet cycle. Neither
`backend_store_status_reuse_safe_i` nor an elapsed interval substitutes for it.
The backend model and implementation must not replay an old status after this
certificate; such a replay violates the certificate contract and is not covered
by the finite namespace guarantee.

## Guarding P29's whole-domain local reset

P29's rearm resets its complete descendant chain, including client-read state,
cache contents, dirty bits and WRITEBACK state. Keeping READ/WB identifiers
unchanged does not preserve that state. P30 therefore requires all of the
following before forwarding reuse-safe into P29:

- P29 is recovery-required after an observed actual `commit_abort_o`; the
  aborted source has subsequently withdrawn valid. Withdrawal is remembered,
  and other pending commit ports may keep their transactions stable.
- Failed STORE reuse-safe and the separate
  `backend_recovery_domain_quiescent_i` certificate are currently asserted.
  This certificate proves that no outstanding external READ response or
  WRITEBACK status can arrive; it does not certify away local dirty data.
- The accepted client-read count is zero; there is no current client response,
  backend READ response, WRITEBACK status, raw backend command, live STORE
  attempt, STORE timeout window or STORE status.
- Local dirty, WRITEBACK busy/terminal/pending/active and recovery state is
  clear, and neither the frozen protocol diagnostic nor the local counter
  protocol diagnostic reports an error.

Client admission is fenced from terminal failure through the complete rearm
interval, with both inner valid and outward ready gated consistently. Existing
responses may drain before reset. Inner commit valid and outward commit
ready/abort are masked during rearm; unselected pending commit sources can
resume afterward. P30 does not automatically replay the aborted transaction.

`client_read_outstanding_o` counts accepted external client requests minus
delivered client responses, including simultaneous events. Its default width is
`$clog2(CLIENT_COUNT * CLIENT_MAX_OUTSTANDING + 1)`, with a minimum of one.
An underflow or overflow is diagnosed without wrapping the count; subsequent
admission and reset remain blocked by the sticky counter error.

## Bounds and diagnostics

A dirty cache or an accepted read that cannot drain while frozen P26 is halted
leaves recovery blocked. The wrapper preserves that state rather than claiming
general recovery progress. Mixed-lane partial effects retain the predecessor's
non-atomic behavior. Prefix wrap can also delay line traffic through the shared
frozen seam; unchanged READ/WB identities do not imply independent progress.

A likely P31 architectural gap is selective STORE recovery that preserves
cache/READ/WB state, or an explicit mechanism to flush and drain a nonempty reset
domain. P30 supplies neither mechanism. It also does not add physical media
persistence, coherence, atomics or complete global ordering.

`store_status_rejected_o` is sticky until global reset. It records a raw STORE
status that was not forwarded, including stale or late status. Rejection is
separate from `protocol_error_o` and does not itself permanently block recovery.
`protocol_error_o` preserves the frozen diagnostic and adds the current/sticky
client-count diagnostic. `recovery_reset_blocked_o` indicates that P29 is halted
and its reset qualifications are unmet; it is low during an accepted rearm.

Global `rst_n` resets the generation allocator and therefore independently
requires all backend STORE, READ and WRITEBACK activity to be quiescent. Local
rearm is not permission to reset the outer allocator. Global reset is a cold,
destructive architectural reinitialization, not a cache flush or a warm recovery
mechanism; this milestone does not claim dirty-data persistence across it.

## Required acceptance evidence

The following is an acceptance map; actual run results are in the canonical receipt. Testbench output
markers alone are insufficient: qualification must retain actual accepting-edge
checks, process results, strict compiler evidence and checkpoint containment.

| Source / configuration | Intended evidence |
| --- | --- |
| `p29_success_then_failure_repro_tb.sv` | The already recorded predecessor failure after a real successful prefix; preserve its failing log independently from canonical P29 PASS. |
| `a0_production_store_commit_generation_tb.sv`, `MODE=0` | First-recovery lower-ID alias containment, another pending commit port, repeated recovery history, old status on a fresh command edge, retry payload/backpressure, and success-only multi-lane retirement. |
| Same STORE testbench, `MODE=1` | Prefix exhaustion, final pre-wrap completion, early-proof non-retention, old status before proof, and truthful all-generation drain before prefix reuse. Include `GEN=1` and a `GEN=3` case; the latter issues beyond the testbench's two-bit local write-ID period before the prefix barrier. |
| Same STORE testbench, `MODE=2`, `TO=1`, `MSR=0` | Same-cycle matching command/status without a ghost live attempt, current matching status priority at the deadline, and stale status failing to mask a real timeout and its fault provenance. |
| `a0_production_store_commit_generation_memory_tb.sv` | Typed READ/WRITEBACK behavior, two real recoveries, pending-read drainage, dirty-state reset blocking, and WRITEBACK-drained but client-pending reset blocking. The external certificate must follow the backend ledger; local checks are assessed independently. |
| Successor parameter and containment qualification | Strict source elaboration for supported widths, unchanged frozen predecessor identities and checkpoint bytes, actual validation outcomes, and retained first-failure evidence. |

Without reviewed canonical evidence and verified checkpoint packaging, the
candidate remains unqualified. Neither an old predecessor receipt nor this
acceptance map substitutes for executing the milestone's qualification.
