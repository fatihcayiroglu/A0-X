# PROD-SEAM-P32 — Resource-ordered independent line progress

P32 is a new local successor to CLOSED P31. P31 and every predecessor remain
byte-identical. This document specifies the implemented contract and the tests
required by the canonical runner; a source file or this document is not evidence
that qualification completed. Only an actual successful runner receipt plus
post-containment and independently verified checkpoint establishes closure.

## Motivation and predecessor boundary

P31 separated STORE-only rearm from live P24 cache, READ and WRITEBACK state. Its
P24 composition retained an upstream P7/P6 ordering precondition. In a focused
frozen-P31 reproduction, an older READ captured OLD memory, a later physical
STORE succeeded, and then the old READ refilled OLD clean cache data. A newer
READ returned OLD despite backend memory containing NEW. This is a missing
local ordering guarantee, not a reason to rewrite P31's frozen qualification.

P17 also captures a dirty eviction victim when accepting a replacement READ.
An exact-line fence alone would not protect a STORE update from a simultaneous
different-line READ that aliases the same resident cache resource. P32 therefore
orders at `(home slice, local set)` granularity, not just exact line address.

## Composition and reset ownership

The new `a0_production_store_commit_ordered_progress_subsystem` contains:

- New `a0_store_read_resource_order_guard`: persistent accepted-READ identity
  ledger and all-raw-commit resource reservations.
- New `a0_store_commit_progress_frontend`: P31 captured commit, classification,
  success/abort and STORE-only rearm behavior, with admitted line service enabled
  during STORE status, fault-consumer, reuse-certificate and generation waits.
- Unchanged P24 persistent dirty cache, requester fabric and READ/WB composition.
- Unchanged P31 STORE attempt-generation guard, and unchanged standalone STORE
  completion and timeout guards from earlier milestones.

Only the STORE completion and timeout guards receive the one-cycle local rearm
reset. The READ ledger, cache data/dirty bits, fabric, WB victim/attempt state,
generation namespace and held shared-command selection receive global reset
only. Global cold reset remains destructive; it is not a flush protocol.

## Admission and ordering contract

Each client has `CLIENT_MAX_OUTSTANDING` slots, each holding live, exact local
tag and line address. Allocation occurs only on an actual upstream/downstream
matching ready/valid handshake. It is not a table of every possible tag value.
Retirement requires exactly one live entry matching the responding client's tag
and exact line. A malformed response cannot free a slot; it latches a sticky
diagnostic and closes new admission. Existing exact responses may still drain.

A matching response can free and reuse a slot/tag on the same edge. Allocation
wins over retirement for that slot. However, STORE eligibility always inspects
the pre-edge registered READ ledger: a conflicting commit is not released
optimistically on its older READ's response edge.

Every enabled lane of every raw-valid commit port reserves its home/set,
including ports not yet chosen by the round-robin frontend. Disabled lanes do
not reserve. New READs to an exact line or a residency alias wait. Other home/set
resources remain eligible subject to existing capacity and fault-admission
rules. A conflicting commit waits outside classification until all older
accepted READs to its resources have delivered real client responses.

An eviction READ owns the existing dirty WB and subsequent replacement refill;
its ledger stays live through that sequence. This protects the old victim until
its real WRITEBACK and replacement complete. Already admitted work is never
retroactively filtered or cancelled. This causal-WB coverage depends on the
current P17 eviction architecture, not an assumed future independent flush.

Raw commit sources must hold valid, lane mask and payload until their actual
success or abort edge. Reservation prevents newly admitted conflicting READs
from withdrawing an already captured source's eligibility. Unrelated outstanding
counts do not gate an active source. Inter-port STORE scheduling remains the
existing captured, serialized round-robin policy.

## Progress, backend identity and backpressure

Line service is enabled whenever global reset is released and the frontend is
not HALT. Thus already admitted READ/WB work can use the real backend while a
STORE waits for status, fault consumption or recovery proof. During a generation
wrap barrier, no new STORE attempt issues until the unchanged guard accepts a
truthful all-generations-quiescent certificate; independent line work may run.

The typed shared ready/valid command interface remains READ, WB or STORE with
the unchanged complete tag/attempt/address/data tuple. READ responses and WB
statuses retain their separate exact-identity inputs. STORE status still uses
generation plus local write/retry identity. Matching success alone retires a
STORE; `commit_abort` remains separate from success-only `commit_ready`.

The outer selector retains a stalled selection and the underlying P23 arbiter
retains its captured line command. A later STORE cannot displace an already
offered READ/WB tuple while ready is low. With no held offer, STORE has priority
over a line command. This is eligible-progress testing, not an unconditional
fairness or latency bound: a permanently deasserted shared ready signal cannot
be bypassed, and continuous STORE pressure has no newly proved fairness bound.

## Required directed qualification

`tests/run_prod_seam_p32.py` requires exact Verilator 5.050, strict zero-warning
and zero-error compilation, no outer or real-inner `-Wno-*` leakage, three
parameter variants and nine simulations:

- Guard: seven scenarios/40 checks, real 10 accepts/10 responses, two malformed
  responses rejected; old READ registered-retire boundary, all ports/lanes,
  resource aliases, per-client tags, capacity and same-edge tag/slot reuse.
- Positive ordering: three drained cold-reset cases for older admitted READ,
  simultaneous alias READ and simultaneous exact-line READ. Each checks dirty
  cache-hit STORE success, later NEW reads, full dirty WB payload including the
  untouched word, exact WB status, replacement and external refill consistency.
- STORE mode0, generation widths 1/2/3, and deadline-one/no-retry: preserve P31
  generation/ABA, stale status, repeated recovery, multiport and multilane,
  success/abort separation, timeout provenance and held retry payload behavior.
- Memory mode0: P31 reset-edge READ/WB/stale/new-STORE cases and exact dirty-byte
  preservation, plus independent READ/WB during status wait and WB/refill during
  fault backpressure and failed-STORE reuse-proof wait.
- Memory MODE1/GEN1: independent READ and dirty WB/replacement progress while a
  pending STORE is blocked at a real exhausted-generation barrier; only a
  truthful certificate releases the next STORE.

The runner executes a fresh unchanged P31 canonical gate, which executes fresh
P30 and P27/P28/P29 predecessors. Each independently instrumented toolchain stream
is audited separately; parent counts must not include child-owned invocations.
Raw command exit codes, process-group completion, log hashes and required unique
markers are checked. Full pre/post path/content/mode containment includes Git
metadata and the raw index. Receipt emission follows final containment.

For the external live repository only, the user approved one bounded exception
on 2026-09-14: metadata path transitions strictly below
`.git/refs/codex/turn-diffs/`. The namespace directory itself and every other Git
path remain strict. Full raw live snapshots and ignored deltas are retained;
historical containment evidence is not rewritten and no refs are modified by
the workflow. Live HEAD, branch, raw index, tracked diff, staged state and source
identity are checked separately. This exception never applies to the isolated
P32 checkpoint or frozen P31/P30/predecessors. A successful external live
supervisor receipt bound to the actual canonical gate receipt is required for
packaging; the isolated gate's policy record alone is not proof of live PASS.

## Retained limitations and subsequent work

P32 does not remove P17's one-miss-per-slice constraint, the P31 fault/new-client
admission fence, or global recovery DRAIN. It adds no rollback of already visible
cache-hit lanes in a partially failed multilane STORE. It does not prove full
cross-cluster coherence, independent dirty flush ordering or atomic transactions.

The resource comparison network is a bounded local seam, not the intended
200+ CU global implementation. Distributed ownership/credits, bank-local hazard
tracking, fair scalable fabric scheduling, many outstanding misses and physical
timing/PPA remain future work. The next local architecture review should examine
the retained global fault-admission/DRAIN boundary and arbitration fairness using
current source and explicit proofs before choosing a bounded successor.

No full-GPU completeness claim follows from this memory seam. VRAM/host IO,
execution/scheduling, graphics, ray tracing, matrix/AI, software, formal/liveness,
synthesis/timing/PPA, FPGA and real workloads require their own implemented and
verified evidence.
