# A0 production multi-CU / shared-L2 wiring

## Scope and topology

This milestone composes a bounded cluster of `CU_COUNT` complete
`a0_multi_wave_core` instances.  Every CU retains its private L1, local MSHR
table, and independent legacy wave-memory request/response interface.  Only
private-L1 line misses enter the existing requester-tagged fabric and shared
L2.  The shared subsystem exposes one global-tagged line backend.

```text
N complete CUs
  -> private L1 / private MSHRs
  -> pre-fabric pending-store gate
  -> requester-tagged line fabric
  -> shared L2
  -> one global-tagged line backend
```

Requester identity is the CU generate index and exists only in
`a0_cu_cluster`.  A core emits an MSHR-entry local tag.  The existing fabric
constructs `{client_id, local_tag}` and restores the local tag on response.
No CU identifier is added to `a0_multi_wave_core` or its private bridge.

The production wrapper proves only `CU_COUNT=1,2,3,4`, including the
non-power-of-two `CU_COUNT=3` case.  It requires `WAVE_SIZE=32`,
`MSHR_LINE_WORDS=8`, `MSHR_COUNT>=2`, `L1_SET_COUNT=64`, one common clock and
reset domain, and enabled load MSHRs.  Width relationships are:

```text
CLIENT_COUNT = CU_COUNT
LOCAL_TAG_W   = max(1, clog2(MSHR_COUNT))
CLIENT_ID_W   = max(1, clog2(CU_COUNT))
GLOBAL_TAG_W  = CLIENT_ID_W + LOCAL_TAG_W
STORE_LANES_PER_CLIENT = WAVE_SIZE
LINE_WORDS = MSHR_LINE_WORDS
```

## Physical-store ordering window

A physical store generation begins on the legacy physical-store launch pulse,
not queue enqueue.  It remains pending through the correctly tagged terminal
legacy response cycle, inclusive, and releases on the next cycle.  Both
success and fault are terminal.  A mismatched wave/context response neither
closes the controller slot nor emits terminal metadata.

The cluster controller retains one lossless scatter-store slot per CU: valid,
owner wave/context, lane mask, and every lane word address.  Several CUs may be
pending at once, and several stores may touch the same line.  A same-line peer
conflict remains until the last matching pending source resolves.

Three defenses cover distinct race positions:

1. **Private-L1 launch broadcast.** Every private L1 sees every CU's raw launch
   cycle.  The boundary flattens `CU_COUNT * WAVE_SIZE` observation lanes and
   valid-gates each source's lane mask.  This preserves resident invalidation,
   refill kill, same-cycle store-vs-hit priority, and install suppression.  No
   persistent pending level enters a private L1, and the L1 source is unchanged.
2. **Pre-MSHR bridge ordering.** A bridge receives wrapper-filtered peer
   raw/pending scatter metadata.  Its work-conserving allocator skips a blocked
   line and may choose an unrelated line/wave.  A blocked candidate cannot
   allocate or merge, and its pending lane state is retained.
3. **Pre-fabric gate.** A miss already committed before a peer store can still
   be waiting at the private-L1/fabric boundary.  For CU `c`:

   ```text
   fabric_valid[c] = core_line_valid[c] && !peer_pending_line_conflict[c]
   core_line_ready[c] = fabric_ready[c] && !peer_pending_line_conflict[c]
   ```

   Payload is unchanged, conflict uses the ungated candidate, and downstream
   ready does not participate in conflict computation.

The shared L2 receives unfiltered raw-or-pending per-CU scatter metadata as a
level observation throughout the pending interval.  The existing shared-L2
logic therefore retains resident invalidation, refill kill, same-cycle
store/refill suppression, and stale-install prevention without source changes.

## Old MSHR generation quarantine

The bridge mirrors only the line of a genuinely new allocation:

```text
mshr_req_fire && mshr_req_allocated
```

It does not rewrite the mirror on a merge.  On any matched terminal store
event, retained terminal scatter metadata sets a sticky quarantine bit for
every still-valid mirrored entry on a touched line.  Terminal metadata is not
self-filtered; a local terminal event may also close a matching old generation.
The effect is qualified by the existing MSHR valid mask:

```text
merge_quarantine_q[e]
&& mshr_valid_mask[e]
&& mshr_entry_line_q[e] == candidate_line
```

The terminal response cycle is still blocked by registered pending state.  At
that edge quarantine is captured.  On the next cycle pending may be clear, but
the still-live old entry remains forbidden as a merge target.  The bit becomes
ineffective and is cleared only when that entry is invalid, so there is no
pending-to-quarantine gap.  The MSHR table itself is byte-identical.

Older waiters committed before store launch remain valid and may receive their
old refill.  They are never cancelled, and old refill forwarding is never
suppressed.  A younger waiter cannot attach to that generation.  After the old
entry disappears, the younger request performs a fresh normal line read.

## External memory contract

> A correctly tagged SUCCESSFUL legacy store response is the visibility point
> of that store in the shared backing memory. A same-line line read accepted
> after that successful response edge must observe the store result.

Tests must therefore update modeled backing memory at matched successful
response, never at launch.  A fault makes no promise that backing memory had no
side effect: invalidation is not rolled back, the pending slot resolves, the old
generation stays quarantined until invalid, and the later fresh read observes
whatever state backing memory legitimately contains.

There is no cross-CU store-data forwarding, ownership/coherence state machine,
atomics, fences, dirty state, writeback, or write allocate.

## Arbitration and A0-X scaling

The private bridge retains round-robin wave arbitration but scans past blocked
candidate lines, preserving unrelated progress.  The existing line fabric
retains requester-tagged round-robin routing and response demultiplexing.  The
controller is bounded to this CU cluster/future L2 slice; this milestone does
not create a flat 200+ CU ordering network.

The A0-X direction is many bounded clusters, locally replicated private
L1/MSHR/order domains, sliced L2, a scalable NoC, and partitioned high-bandwidth
memory controllers.  The local controller and per-bridge quarantine are
replicable without changing `a0_mshr_table` semantics.

## Targeted validation

The targeted runner requires exactly 43 scenario markers.  Scenarios 1-34 are
the existing RTL9D-3 shared-fabric/shared-L2 integration matrix.  Scenarios
35-43 are the following frozen ordering/quarantine races:

35. `SAME_CYCLE_STORE_LAUNCH_VS_MSHR_MERGE_STORE_WINS`
36. `YOUNGER_LOAD_CANNOT_MERGE_INTO_PRE_STORE_OPEN_MSHR`
37. `OTHER_LINE_MSHR_MERGE_REMAINS_ALLOWED`
38. `PEER_STORE_FAULT_RELEASES_YOUNGER_MSHR_REQUEST`
39. `MULTIPLE_CU_PENDING_STORES_DIFFERENT_LINES`
40. `MULTIPLE_PEER_STORES_SAME_LINE_BLOCK_UNTIL_LAST_RESOLVE`
41. `YOUNGER_LOAD_BLOCKED_WHILE_OLD_MSHR_REFILL_RETURNS`
42. `RESPONSE_CYCLE_INCLUSIVE_BLOCK` (including no old draining-data consume)
43. `MISMATCHED_STORE_RESPONSE_DOES_NOT_ENABLE_MERGE`

The controller TB separately proves raw/pending handoff, scatter retention,
success/fault terminal equivalence, mismatch rejection, multi-CU independence,
same-line last-resolver behavior, and `CU_COUNT=3` indexing.  The cluster TB
elaborates three complete cores plus the production shared path and checks the
integrated reset/idle and tag-width wiring.  Strict lint elaborates CU counts
1-4 and MSHR counts 2-4.  The recursive gate then runs RTL9D-3 and its complete
predecessor chain.

## Frozen patch scope

New files (7):

- `docs/architecture/A0_PRODUCTION_MULTI_CU_SHARED_L2_WIRING.md`
- `rtl/core/a0_cu_cluster.sv`
- `rtl/memory/a0_cluster_store_order_controller.sv`
- `tests/rtl/a0_cluster_store_order_controller_tb.sv`
- `tests/rtl/a0_cu_cluster_shared_l2_tb.sv`
- `tests/run_production_multi_cu_shared_l2.py`
- `tests/run_production_multi_cu_shared_l2_gate.py`

Modified files (16):

- `rtl/core/a0_multi_wave_core.sv`
- `rtl/memory/a0_memory_service_boundary.sv`
- `rtl/memory/a0_wave_load_mshr_bridge.sv`
- `tests/rtl/a0_multi_wave_core_rtl7b_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl7c_memory_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl7c_memory_edges_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl8b_mshr_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl8b_mshr_edges_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl8b_store_serial_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl8c_load_bypass_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl8c_multi_store_tb.sv`
- `tests/rtl/a0_multi_wave_core_rtl9c1_l1_tb.sv`
- `tests/rtl/a0_memory_service_boundary_tb.sv`
- `tests/rtl/a0_memory_service_boundary_rtl9b2_tb.sv`
- `tests/rtl/a0_wave_load_mshr_bridge_tb.sv`
- `tests/run_rtl9c1_core_l1.py` (header SHA only)

Every other baseline tracked file is identity-checked.  In particular the MSHR
table, private L1, fabric, shared L2, shared subsystem, store queue, and existing
gate runners remain byte-identical.
