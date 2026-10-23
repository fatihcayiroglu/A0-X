# PROD-SEAM-P33 — Resource-scoped STORE-fault quarantine

P33 is a local successor to CLOSED P32. P32 and every predecessor remain
byte-identical. This document describes the implemented candidate and the
canonical proof contract. It is not closure evidence: P33 is CLOSED only after
the canonical runner, fresh predecessor chain, bounded-live containment audit
and checkpoint readback all pass.

## Motivation and predecessor boundary

P32 prevents an accepted old READ from refilling stale data after a newer STORE
and lets already-admitted READ/WRITEBACK work progress while STORE waits for
status, fault consumption or generation-reuse proof. It deliberately retained a
global frontend fence on new clients during terminal STORE failure, FAULT,
ABORTED, REARM and DRAIN. Its DRAIN exit also waited for every unrelated READ and
WRITEBACK to become idle. Consequently, one failed STORE could deny independent
new line work and could make local STORE rearm depend on unrelated live work.

P33 removes those two global recovery dependencies while preserving the P32
ordering guarantee. The failed STORE's captured resources remain quarantined;
new READs to disjoint resources may be admitted and complete. Recovery restarts
only STORE completion/timeout state and does not reset or fabricate cache, READ,
WRITEBACK, requester, retry, generation or fabric state.

This is a bounded production seam. It does not cancel a physical write already
accepted by the backend, roll back visible cache-hit lanes, or introduce a full
coherence protocol.

## Composition and reset ownership

`a0_production_store_commit_scoped_progress_subsystem` contains:

- `a0_store_read_quarantine_order_guard`, which retains P32's accepted-READ
  ledger and raw-commit reservations and adds captured failed-STORE resource
  reservations.
- `a0_store_commit_scoped_recovery_frontend`, which retains P32 classification,
  generation/ABA protection, success-only retirement and separate abort, while
  exposing captured reservation identity throughout every non-IDLE state.
- The unchanged P24 persistent dirty cache, requester-tagged fabric, READ and
  WRITEBACK machinery.
- The unchanged P31 STORE attempt-generation guard and unchanged standalone
  STORE completion and status-timeout guards.

The one-cycle local recovery reset still reaches only the STORE completion and
timeout guards. Cache lines, dirty bytes, accepted-READ ledger, requester tags,
READ miss state, WRITEBACK victim/payload/attempt state, generation namespace,
held line command and shared-command selection receive global reset only.
Global cold reset remains destructive and is not a cache flush protocol.

## Captured quarantine contract

Each raw-valid commit port reserves every enabled lane's `(home slice, local
set)` before capture, exactly as in P32. Once a commit is captured, the frontend
publishes the captured lane mask and addresses for every non-IDLE phase,
including classification, issue/status wait, terminal failure, FAULT,
ABORTED, REARM and DRAIN. The guard takes the union of raw and captured
reservations.

That union has two required consequences:

1. Source withdrawal or post-abort changes on now-invalid raw payload wires
   cannot erase or move the failed STORE's reservation.
2. A new READ that aliases any captured failed-STORE home/set waits, while a
   READ to an independent resource remains eligible under existing capacity and
   protocol-diagnostic rules.

The captured reservation is released only after DRAIN completes. A READ that
was blocked by the reservation remains blocked on the final DRAIN edge and may
be accepted on a later edge. This explicit boundary prevents an optimistic
same-edge release from bypassing the failed STORE's recovery ordering.

Accepted READ entries continue to retire only on one exact client/tag response.
Malformed responses cannot free a slot and latch the existing sticky diagnostic.
Allocation still wins over retirement for same-edge slot reuse. STORE
classification still observes the pre-edge registered READ ledger, so an older
conflicting READ does not release a STORE on its response edge.

## Admission, recovery and same-cycle behavior

New client admission is fenced only by global reset, HALT and the existing
sticky protocol diagnostics. A held terminal failure or a low reuse certificate
does not globally fence independent READ work. Conflicting work remains blocked
by the resource guard, and already-admitted work is never cancelled.

The STORE state progression remains terminal failure to FAULT, ABORTED, REARM
and DRAIN. FAULT requires explicit consumer acceptance. ABORTED requires source
withdrawal before proceeding. REARM still requires backend reuse-safe, an idle
STORE attempt, an idle P24 commit router and no protocol error. The local reset
then rearms only STORE completion/timeout tracking.

DRAIN now waits only for the STORE attempt and P24 commit router to be idle and
for protocol errors to remain clear. It does not wait for unrelated READ or
WRITEBACK state to drain. Thus a replacement READ may remain live or
backpressured as STORE recovery finishes. The captured quarantine remains
effective through that DRAIN edge.

READ responses, WRITEBACK statuses and stale STORE statuses retain their typed
identity checks on every recovery edge. A same-cycle exact READ response or WB
status completes its pre-existing transaction exactly once. A stale STORE
status cannot complete a fresh generation. A new STORE source may be present on
a recovery edge but is accepted only according to the normal post-recovery
ready/valid boundary. `commit_ready` remains success-only and `commit_abort`
remains a distinct terminal event.

## Backend identity, arbitration and retained limits

The shared backend command is still typed READ, WB or STORE and carries the full
requester/tag or write-attempt identity and exact address/data payload. READ
responses and WB statuses use their existing independent return paths. STORE
status uses generation plus local write/retry identity. Backpressured commands
retain a stable full tuple; no recovery event fabricates a backend completion.

The outer held selection and the P23 captured line command are unchanged. A
later STORE cannot displace an already offered READ/WB command while ready is
low. With no held offer, existing STORE-over-line selection priority remains.
P33 proves independent eligible work can progress across STORE fault recovery;
it does not claim a fairness bound under permanent backpressure or continuous
STORE pressure.

P33 also retains P17's one-miss-per-slice limit, bounded comparison networks,
serialized captured STORE scheduling and the absence of cross-cluster
coherence. These are not the intended 200+ CU final topology. Distributed
ownership, scalable sliced hazard tracking, credit-based/fair NoC service, many
outstanding misses, HBM/VRAM integration and physical timing/PPA remain future
milestones.

## Canonical directed qualification

`tests/run_prod_seam_p33.py` requires exact Verilator 5.050, strict zero-warning
and zero-error compilation, zero outer and real-inner `-Wno-*` leakage, three
parameter variants and nine simulations:

- Quarantine guard: eight scenarios/49 checks, 14 real accepts and 14 real
  responses, with two malformed responses rejected. In addition to all P32
  ledger cases, it proves raw-plus-captured reservation union, source-withdrawal
  persistence and post-DRAIN release.
- Positive ordering: the three P32 drained dirty-cache cases continue to prove
  old READ ordering, alias/exact reservation, byte-exact dirty WRITEBACK and
  NEW refill visibility.
- STORE mode0, generation widths 1/2/3 and deadline-one/no-retry retain the P31
  generation-wrap/ABA, stale-status, retry payload, multilane, multiport,
  success/abort and timeout-provenance contracts.
- Memory mode0 retains the P31/P32 dirty-state and same-cycle READ/WB/stale/new
  STORE scenarios, then proves: an independent READ completes during held
  FAULT; captured aliasing survives source withdrawal and mutated invalid raw
  payload; independent READ completes while reuse proof is low; captured alias
  remains blocked through DRAIN; and DRAIN releases with an unrelated
  replacement READ still live/backpressured.
- Memory MODE1/GEN1 retains independent READ and dirty WB/replacement progress
  across an exhausted-generation barrier, released only by a truthful reuse
  certificate.

The runner executes a fresh unchanged P32 canonical gate. That child executes a
fresh P31 gate, which executes fresh P30 and P27/P28/P29 predecessors. Every
toolchain stream has separate raw invocation accounting; parent counts never
absorb child-owned calls. The runner audits exact command exit codes, process
completion, log hashes, unique markers, event counts, source pins, receipts,
Git identity, raw index and full isolated pre/post containment before emitting
PASS.

For the external live repository only, the user-approved bounded containment
exception remains exactly metadata descendants below
`.git/refs/codex/turn-diffs/`. The namespace root and every other `.git` path
remain strict. The exception never applies to isolated P33, frozen P32/P31/P30
or historical evidence. Live source, HEAD, branch, raw index, semantic index,
tracked diff, staged state and frozen checkpoint identities remain strict. A
fresh external supervisor receipt bound to the canonical P33 receipt is required
before packaging.

P33 does not establish full-GPU completeness. Memory/coherence beyond this seam,
VRAM and host IO, SIMT execution and scheduling, LDS/barriers, command and DMA,
graphics, texture, raster/ROP, ray tracing, matrix/AI, compiler/runtime/driver,
formal liveness, synthesis/timing/PPA, FPGA and real workloads require separate
implemented and verified evidence.
