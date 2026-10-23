# P34 — cache-backed probe and ownership-transfer development contract

Source-freeze status: IMPLEMENTED and INTEGRATED as additive P34 production
successors; external development qualification has passed. Canonical gate,
bounded promotion and checkpoint closure are separate receipt-bound steps.
This source document does not itself assert canonical PASS or CLOSED.

Frozen predecessor: verified P33 CLOSED ZIP SHA256
`62f7ec115cb55fb101ae6542e58106f33c2cd990b6a29fcc4d1784c098f0a92b`.
All predecessor RTL/tests/artifacts remain unchanged. The new endpoint is a
successor to the actual P17 cache storage, not a shadow-directory model.

## First implementation boundary

`a0_l2_coherence_probe_slice` retains the P17 local READ, resident STORE and
dirty-victim interfaces. One successor-only admission correction gives raw
STORE priority over a new READ aliasing the same set: otherwise an eviction
could snapshot old bytes on the edge that accepts a STORE to its victim. No
frozen predecessor code is patched. Directed clean/dirty alias scenarios must
prove the updated bytes reach WRITEBACK after the blocked READ is later admitted.
It adds one probe at a time, an accepting receiver
handoff, and explicit ownership return. Three development configurations cover
one-word/one-set/one-bit generation, four-word/four-set/two-bit generation and
eight-word/eight-set/three-bit generation boundaries.

This first component is not a scalable directory or a network acknowledgement
protocol. The probe response ready/valid edge must mean the receiver actually
accepts the complete line and its dirty responsibility. Enqueuing a packet in
an unreliable transport is not that guarantee. Production transport integration
must supply a trustworthy accepting boundary before this contract can apply.

## Ordering and data ownership

QUERY snapshots a resident hit, dirty bit and every data word without changing
ownership. TRANSFER snapshots the same tuple, but transfers responsibility only
on an accepted response. Offering a response does not invalidate, clean or free
dirty data. The held identity and full data remain stable during backpressure.

Probe ready stays low until older same-set READ/miss, hit response and eviction
work is gone, including the refill and WB-release edges. Both eviction victim
and replacement sets count as reserved resources. A raw probe request reserves
its set against new local READ/STORE admission. Multi-lane STORE conflicts block
the whole STORE, not an unchecked subset. Independent sets may progress subject
to the inherited one-miss-per-slice capacity bound. An external `probe_block_i`
must carry the production accepted-client READ ledger and raw/captured STORE
quarantine; it may block capture but must never cancel a held response.

Production admission must suppress the effective probe valid sent into this
primitive while an older accepted-client READ or raw/captured STORE blocks it.
Merely lowering probe ready is insufficient: the primitive's raw reservation
would otherwise stall the older fabric request needed to release that blocker.
An upstream guard must still reserve raw probe resources against new client
READs. Raw STORE ports take priority over an unaccepted probe; already accepted
probe/remote reservations block new frontend STORE capture. Do not confuse
frontend capture with success-only commit_ready retirement.

A successful TRANSFER hit invalidates the source cache only on receiver
acceptance and installs a remote-owner reservation for the exact source set.
Both exact-line and alias local requests remain blocked. This is essential:
backing memory may still contain old bytes, so unrestricted refill would revive
stale data. A miss probe transfers nothing and consumes no generation.

Ownership return (reclaim) must match stored line, receiver node and the
source-issued generation. The receiver supplies the full current line and its
dirty responsibility. Only that accepted exact tuple installs local cache data
and releases the reservation. A stale/wrong return cannot mutate the cache or
release the current owner. Pre-edge reservation blocks optimistic local use on
the return edge. A return is an ownership handoff, not a durability certificate;
if memory remains stale, the returned dirty bit must remain true.

## Identity and finite namespace

Probe requester node and transaction ID are echoed exactly. Source generations
are allocated monotonically per slice on accepted TRANSFER hits and never wrap
silently. Once exhausted, further TRANSFER requests wait; QUERY remains possible.
Namespace rearm requires a new LOW then HIGH reuse-safe certificate observed
after exhaustion, no remote ownership, no pending probe and no READ/eviction/hit
buffer state. This certificate means no old return can arrive. The source cannot
prove a lying external certificate; the environment owns that obligation.
Namespace rearm never resets cache, READ, WRITEBACK or STORE state. Global cold
reset remains destructive and is not a coherence flush or recovery operation.

Invalid self-TRANSFER and wrong reclaim tuples produce separate protocol
diagnostics, not successful handshakes. Existing unexpected-memory-response
diagnostics retain their predecessor meaning.

## Implemented production composition

The additive hierarchy is:

`a0_production_store_commit_coherent_progress_subsystem`
-> `a0_production_store_commit_coherent_l2_subsystem`
-> `a0_mc_noc_coherent_l2_unified_backend_subsystem`
-> `a0_mc_noc_coherent_multislice_writeback_subsystem`
-> `a0_l2_coherent_multislice_writeback_subsystem`
-> `a0_l2_coherent_recoverable_writeback_slice`
-> `a0_l2_coherence_probe_slice`.

Frozen requester fabric, WB queue/completion/recovery, typed backend arbiter,
STORE routing/completion/timeout/generation and P33 scoped recovery frontend
remain reused without modification. Cache/READ state uses global reset;
STORE-only recovery does not reset it or the coherence generation allocator.
WB-local completion recovery retains its inherited separate reset boundary.

The successor order guard keeps the exact accepted-client READ ledger. For
each `{home,set}`, C is registered pending-probe/remote ownership, R is pre-edge
accepted READ work, S is all enabled raw and captured STORE lanes, and P is a
raw offered probe. New READ admission blocks on C|S|P; new frontend STORE
capture blocks on C|R; probe capture blocks on R|S. Probe blocking suppresses
the child valid, not merely ready, allowing older retained work to drain.
Captured STORE quarantine lasts through source withdrawal and recovery DRAIN.
Retirement remains success-only; abort remains an independent fault handshake.

Home is low `SLICE_ID_W` bits of line XOR those of line shifted by
`SLICE_HASH_SHIFT` (home zero for a singleton). Both probe and reclaim home
fields are checked against this mapping. The bank permits one accepted probe
response globally, retains its home through response acceptance and ignores
inactive/new request routes for that response. Reclaim bypasses the bank probe
lock and STORE admission block, then checks the source-local line/node/generation.
Per-slice generation values are not globally unique; home is part of identity.
Coherence route/tuple rejection pulses are separate from legacy protocol faults.

The public typed memory boundary retains READ requester/tag/line, WB source and
attempt identity plus full dirty bytes, and STORE attempt/generation/word/data.
It is not HBM/DDR timing, a scalable directory, or an unreliable-transport retry
protocol. The probe ready/valid handoff still requires an accepting receiver.

## Measured development evidence

The unit suite passed 23/24/24 scenarios and 1188/1672/2508 checks for
words/sets/generation-width 1/1/1, 4/4/2 and 8/8/3. It covers finite generation
exhaustion/reuse, dirty handoff/reclaim, stale tuples, alias STORE priority,
refill/WB ordering and response backpressure.

The production suite passed strict RTL lint for three inherited ONE/TWO/WIDE
parameter configurations, three integrated simulations and nine adapted P33
regressions. Integrated slices/sets/words 1/1/1, 2/2/2 and 4/4/4 passed
19/22/22 scenarios and 3434/4495/5543 checks respectively. Accepted/returned
client counts were 9/9, 13/13 and 13/13; physical READ counts 2/2, 4/4 and 4/4;
each variant observed exactly one WB and one terminally failing physical STORE,
five TAKE/reclaim handoffs, five rejected reclaim tuples and one STORE rearm.
Probe counts were 13/13, 14/14 and 14/14. Payload/identity checks use actual
public handshakes and an independent receiver/backend model, not private arrays.

New integrated boundaries include accepted QUERY/TAKE response backpressure
blocking READ and frontend STORE capture, retained raw local work across exact
reclaim, and (multi-set variants) reclaim/local progress while a different-set
QUERY response remains held. Existing checks cover old READ drain, raw STORE
priority, exact/alias remote holds, disjoint home/set progress, generation
exhaustion/rearm, dirty victim WB bytes and captured STORE recovery quarantine.
The adapted nine-test suite covers STORE retries, three generation-wrap widths,
deadline provenance, READ/WB survival, memory wrap, ordering and ledger edges.

Production development work: `/tmp/a0_p30_p34_production_development_q7aflx14`.
Component work: `/tmp/a0_p30_p34_probe_warning_repair_duik2ap1`.
Both use exact Verilator 5.050, zero diagnostics, zero outer/inner suppression,
and passed source/raw-index/isolated/frozen/bounded-live post-containment.
Historical warning, capacity and width failures remain evidence, not PASS runs.

Coverage limits: the receiver model owns one transferred line at a time.
Simultaneous multiple remote owners and selective return among them are not
claimed as tested. Reclaim during captured STORE quarantine is not directly
exercised; reclaim during held probe and waiting unaccepted local work is.
No assertion here claims a complete multi-agent coherence protocol or liveness.

## Canonical qualification and closure boundary

The P34 successor harness may use an explicit validated external work-root.
Only its workspace allocation differs from frozen support; strict flags, exact
toolchain archive, command timeouts, process-group termination/reaping and full
checkpoint/raw-index containment remain unchanged. In this qualification plan
P34 uses D: capacity, while fresh unchanged P33/P32/P31/P30 runners retain native
`/tmp`. Both filesystems require at least 3 GiB at preflight. Negative root-path,
real bootstrap, deterministic timeout/reap and read-only predecessor raw-auditor
self-tests precede canonical invocation. This is not a frozen predecessor patch.

Before CLOSED: directed unit and production tests, three parameter variants,
exact Verilator 5.050, warnings/errors zero, outer/real-inner suppression zero,
fresh unchanged P33/predecessor chain, raw accounting and source/index/live
containment, canonical receipt and verified manifest/CRC/rehydrated checkpoint.
Only live metadata descendants under `.git/refs/codex/turn-diffs/` may be excluded
from live containment; the namespace root and all other paths remain strict.

No full-system coherence, 200+ CU scaling, fairness/liveness bound, HBM integration,
PPA, FPGA/workload result or complete-GPU claim follows from this bounded endpoint
integration milestone. The long-term distributed/sliced-cache and scalable-fabric
architecture remains the target; this is not a substitute for later proof.
