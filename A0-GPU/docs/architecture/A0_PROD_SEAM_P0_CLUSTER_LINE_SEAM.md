# A0-X PROD-SEAM-P0: Production Cluster Line Seam

## Status and bounded purpose

PROD-SEAM-P0 extracts the already-closed cluster-local requester fabric and
physical-store observation fan-in from `a0_shared_l2_subsystem` into an L2-free
module named `a0_production_cluster_line_seam`.

This is a migration seam, not a cache or NoC redesign.  The frozen production
cluster and shared-L2 wrapper remain unchanged.  The new module permits a
future production cluster frontend to terminate either at the existing L2 or
at the already-closed MC-NOC endpoint without duplicating requester identity,
arbitration, or store-observation logic.

The milestone is deliberately narrower than full production rewiring:

- existing core, L1, MSHR, and cluster store-order logic is unchanged;
- existing `a0_line_request_fabric` is instantiated, not reimplemented;
- existing `a0_l2_line_cache` is unchanged;
- `a0_cu_cluster` and `a0_shared_l2_subsystem` are unchanged;
- no NoC component is instantiated;
- no live production top selects the new seam in P0.

## Recovered source boundary

The current production path is:

```text
CU cores / private L1 / load MSHRs
        |
cluster store-order controller and peer-conflict gating
        |
per-CU line requests {local MSHR entry, line address}
        |
a0_shared_l2_subsystem
  [a0_line_request_fabric + store flattening + a0_l2_line_cache]
        |
one global-tagged external line-memory interface
```

The true post-local-fabric boundary was internal to
`a0_shared_l2_subsystem`.  P0 exposes precisely that boundary:

```text
per-CU clients
        |
a0_production_cluster_line_seam
  [closed a0_line_request_fabric + store flattening]
        |
one request stream {global tag, line address}
one response stream {global tag, line address, fault, line data}
one flattened physical-store observation
```

## Interface contract

### Client side

There are `CLIENT_COUNT` requesters.  Each requester supplies:

- request valid/ready;
- an opaque `LOCAL_TAG_W` local tag;
- a line address;
- physical-store valid, lane mask, and word addresses.

Each requester receives a one-cycle response indication containing the
original local tag, line address, fault, and complete line data.  The current
line-response contract has no ready/backpressure signal; P0 preserves it.

### Exposed line seam

The downstream request is ordinary ready/valid.  A request accepted from
client `c` carries:

```text
global_tag = {client_id(c), local_tag}
```

`CLIENT_ID_W` is one bit for a single client and otherwise
`clog2(CLIENT_COUNT)`.  `GLOBAL_TAG_W` is `CLIENT_ID_W + LOCAL_TAG_W`.
The line fabric retains one registered request hold, preserves payload under
backpressure, and advances its round-robin cursor on accepted client input.

Responses may return out of order.  Their requester field selects one client;
the local field is returned without translation.  An invalid encoded client
identifier asserts `line_resp_tag_error_o` and produces no client response.

### Store-observation sideband

The downstream store observer has
`CLIENT_COUNT * STORE_LANES_PER_CLIENT` lanes.  Flattened lane index is:

```text
flat_lane = client * STORE_LANES_PER_CLIENT + client_lane
```

The flattened valid is the OR of all client store-valid inputs.  Each mask bit
is gated by its client valid.  Every word address is copied independent of
validity; consumers qualify it with the corresponding valid and mask.

This sideband is visibility metadata only.  Store data, store execution,
write allocation, and ordering policy do not pass through this module.

## Behavioral preservation proof

`a0_production_cluster_line_seam_equivalence` forms a one-time migration
harness:

1. one side instantiates the frozen `a0_shared_l2_subsystem`;
2. the other side instantiates the P0 seam followed by the unchanged
   `a0_l2_line_cache`;
3. both sides receive identical client, store, and backend stimuli;
4. client outputs, backend requests, errors, the extracted request seam, and
   flattened store observation are compared cycle by cycle;
5. the hash-locked RTL9D-3 integration scenario source is mechanically adapted
   only at its DUT type and test-top name, then replayed unchanged.

The reference's internal seam names are used only inside this hash-locked
migration harness so that extraction can be compared at the exact old
boundary.  They are not declared as a production API and must not be copied
into later functional tests.

The replay covers reset, cold miss/refill, shared hits, same-local-tag
multi-client uniqueness, multiple outstanding and out-of-order responses,
full-MSHR backpressure, stable request hold, round-robin opportunity,
cross-client store invalidation, killed refill behavior, same-cycle
store/refill precedence, simultaneous store fan-in, faulted refills, malformed
requester response tags, and final drain/idle.

The candidate runner also lint-elaborates parameter points with one,
non-power-of-two, production-sized, and larger client counts.  This establishes
width consistency and warning cleanliness; it is not a timing or PPA result.

## Preserved invariants

- Requester identity remains owned outside each core.
- A core-local MSHR entry remains the opaque local request tag.
- The cluster-local global tag remains `{CU/client ID, MSHR/local tag}`.
- The closed request fabric still owns request holding and arbitration.
- The downstream response remains no-backpressure in this production seam.
- Physical stores remain outside the load-line request fabric.
- Store observations remain conservative and can invalidate or kill matching
  downstream cache refills exactly as before.
- L2 hit, miss tracking, refill, invalidation, and fault policy remain entirely
  in the unchanged L2 primitive.
- The current external line-memory protocol is unchanged.

## Explicit non-goals

PROD_SEAM-P0 does not provide or claim:

- full `a0_cu_cluster` rewiring;
- connection to `a0_cluster_line_noc_endpoint`;
- multi-cluster production execution;
- store transport over the logical NoC;
- cross-cluster store visibility or coherence;
- response buffering beyond the closed current line-response contract;
- same-line miss merging;
- a physical NoC, virtual channels, credits, CDC, or link retry;
- memory-controller scheduling or high-bandwidth-memory channels;
- timing closure, frequency, area, power, or physical scalability proof.

```text
PROD_SEAM_P0_TIMING=NOT_MEASURED
PROD_SEAM_P0_PPA=NOT_MEASURED
PROD_SEAM_P0_COHERENCE=NOT_IMPLEMENTED
PROD_SEAM_P0_PHYSICAL_NOC=NOT_IMPLEMENTED
PROD_SEAM_P0_PRODUCTION_WIRING=NOT_IMPLEMENTED
```

## Closure criteria

P0 may close only when all of the following pass with the frozen Verilator
5.050 identity and without changing the live repository during isolated
qualification:

- exact live baseline and closed P5 source identity;
- warning-clean static compilation;
- complete RTL9D-3 scenario replay through the equivalence harness;
- cycle-by-cycle reference equality throughout that replay;
- parameter lint matrix including a 64-client structural point;
- full P5 recursive closed-source regression in an isolated projection;
- post-run candidate, toolchain, and live-repository containment.

Passing P0 proves that the internal production line boundary can be exposed
without changing the existing shared-L2 behavior.  It does not prove that a
new production frontend has adopted that boundary.

## Evidence-based next bounded milestone

`PROD-SEAM-P1` should add a new-file-only successor production cluster
frontend that contains the existing cores, private L1/MSHR path, store-order
controller, peer-conflict gating, and P0 seam, but no embedded L2.  It must be
checked against `a0_cu_cluster` across load, store, fault, reset, refill-kill,
tag-error, and cross-CU ordering scenarios before any MC-NOC connection.

Only after that production frontend is equivalent should a later milestone
connect its exposed line seam to `a0_cluster_line_noc_endpoint`.  Store
visibility and cross-cluster coherence remain separate architecture decisions.
