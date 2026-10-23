# A0 MC-NOC-P5 logical-NoC foundation freeze

## Status

MC-NOC-P5 closes Phase A without changing DUT RTL. It freezes the verified
load-line transport assembled by MC-NOC-P0 through MC-NOC-P4 and provides one
recursive gate for that complete foundation.

This milestone adds only:

```text
docs/architecture/A0_MC_NOC_P5_LOGICAL_NOC_FREEZE.md
tests/run_mc_noc_p5_gate.py
```

It adds no RTL, testbench, queue, virtual output queue, injection lane,
coherence state, store path, or physical topology.

## Frozen logical path

The closed Phase-A request and response path is:

```text
one scalar post-local-fabric line stream per cluster
  -> one unchanged P0 elastic request endpoint per cluster
  -> P2 ownership reservation around the unchanged P1 request router
  -> one independent P1 RR arbitration domain per address-selected home slice
  -> one registered P3 no-bypass elastic seam per slice
  -> one unchanged V12-style L2 line cache per slice
  -> one independent abstract line-memory backend per slice

backend/L2 no-ready response
  -> exact P2 reserved owner selected by network tag and expected line/home
  -> one independent P2 completed-owner RR service domain per cluster
  -> one unchanged P0 elastic response endpoint per cluster
  -> exact local {CU_ID, LOCAL_TAG} restoration
```

The network tag remains:

```text
NETWORK_TAG = {CLUSTER_ID, CU_ID, LOCAL_TAG}
```

The home slice remains address-only. Cluster identity never participates in
the home hash, so every cluster maps the same physical line to the same slice.

## Closed milestone responsibilities

### P0: cluster line endpoint

P0 defines the cluster boundary and preserves request/response packets in
registered one-entry elastic holds. It proves stall stability, exactly-once
drain, independent request/response progress, and same-edge turnover.

### P1: logical request routing

P1 maps each address to one home slice and arbitrates same-home cluster heads
with an independent round-robin cursor per slice. The cursor advances only on
a successful downstream handshake. A stalled destination does not stall an
independent slice.

### P2: transaction ownership and response routing

P2 reserves bounded per-cluster owner state before request injection. It
checks response identity against the reserved network tag, expected line, and
expected home, captures independent legal no-ready slice responses, rejects
malformed/orphan/duplicate responses, and returns completed owners using an
independent round-robin cursor per cluster. Same-edge retire/reuse is part of
the frozen contract.

### P3: sliced-L2 composition

P3 composes K endpoints, one P2 router, S registered request seams, S L2
caches, and S abstract backends. The seam removes the direct P2-valid to
L2-ready combinational cycle while retaining no-bypass, stable hold, and
same-edge dequeue/replacement behavior.

### P4: parameterization, fairness, and HOL evidence

P4 changes no DUT RTL. It validates five materially different functional
configurations, including non-power-of-two identity widths, and elaborates a
K=64, U=4, M=4, S=64 configuration representing 256 CUs. P4 directly proves
P1 sustained same-home fairness in accepted service opportunities. The closed
P2 regression preserves its separate completed-owner opportunity bound.

P4 characterizes, rather than hides, scalar request HOL, per-slice miss-table
saturation, per-cluster response serialization, hash hotspots, and the
strict-priority backend-response effect on the one-entry L2 hit hold.

## Parameter and state model

Let:

```text
K  = cluster count
U  = CUs per cluster
M  = local MSHRs per CU
O  = U*M owner slots per cluster
S  = L2 slice count
N  = sets per L2 slice
Q  = miss trackers per L2 slice
W  = 32-bit words per line
A  = 32-log2(W) line-address bits
b(x) = max(1, ceil(log2(x)))
CID  = b(K)
CUID = b(U)
LT   = b(M)
CLT  = CUID+LT
NT   = CID+CLT
SID  = b(S)
OW   = b(O)
TAG  = A-log2(N)
```

Frozen registered-state accounting is:

```text
P0 = K * (3 + NT + CLT + 2*A + 32*W)
P1 = S * (CID + 1 + NT + A)
P2 = K*O * (4 + NT + A + SID + 32*W) + K * (1 + 2*OW)
P3 = S * (1 + NT + A)

L2 = S * [N*(1 + TAG + 32*W)
          + Q*(2 + NT + A)
          + (1 + NT + A + 32*W)]
```

For the P4 structural configuration
`K=64 U=4 M=4 W=8 S=64 N=256 Q=16`:

```text
TOTAL_CUS=256
ROUTING_REGISTERED_BITS=339584
L2_REGISTERED_BITS=4615680
COMBINED_REGISTERED_BITS=4955264
P1_CANDIDATE_SITES=4096
P2_SAME_CYCLE_SITES=4096
L2_REQUEST_LOOKUP_SITES=1024
L2_RESPONSE_LOOKUP_SITES=1024
```

These are structural source counts, not placed area, power, frequency, or
throughput measurements.

## Fairness and throughput contract

With a continuously available home slice and continuously eligible cluster
heads, P1 serves every contender within at most `K` accepted service
opportunities. Ready-low clocks are not opportunities and must preserve the
held packet.

With a continuously ready local response consumer, P2 selects every completed
owner within at most `O` retirement opportunities. This is not an unconditional
cycle-latency bound.

The scalar public cluster contract permits at most one accepted request and
one accepted response per cluster per opportunity. Across balanced homes the
structural request/response rates are bounded by `min(K,S)` globally and one
per cluster. Same-home traffic is bounded by one accepted request at that
slice per opportunity.

No Fmax, STA, synthesis-area, power, or physical-wire measurement is present:

```text
MC_NOC_P5_TIMING=NOT_MEASURED
MC_NOC_P5_PPA=NOT_MEASURED
MC_NOC_P5_RTL_OPTIMIZATION_REQUIRED=NOT_INFERRED
```

## Explicit architecture debt

Phase A closes with the following visible debt, not with a claim that the
current hierarchical crossbar is a final 256-CU physical implementation:

1. One scalar request head per cluster exposes destination HOL.
2. P1 arbitration work grows as `K*S`.
3. P2 admission grows as `K*O`, request issue and response matching each grow
   as `S*O`, and same-cycle cross-slice checking grows as `S*S`.
4. Each L2 slice performs separate linear `Q`-entry request and response
   tracker searches.
5. The full ready chain can span backend availability, an L2 tracker search,
   the P3 seam, a P2 owner search, P1 arbitration, P2 admission, and P0.
6. A local response stall serializes later completions for that cluster.
7. A legal continuous backend-response stream can postpone a buffered L2 hit;
   the abstract backend has no response-ready signal.
8. The XOR home hash can be driven into a hotspot by adversarial addresses.
9. There is no credit protocol, virtual channel, virtual output queue,
   multi-lane endpoint, physical link, or topology-dependent routing.

P4 found no repository-backed timing or throughput target whose violation
would justify adding VOQs, deeper queues, or lanes now. Those mechanisms
remain evidence-triggered successors rather than speculative P5 RTL.

## Deliberate exclusions

The frozen Phase-A path is load-line-only and isolated from production. It is
not evidence for:

```text
cross-cluster stores
coherence or a directory
atomics or device/system memory scopes
dirty eviction or writeback
a physical ring/mesh/hierarchical mesh
credits or virtual channels
production multi-cluster CU execution
memory-controller scheduling or a DRAM PHY
timing closure, PPA, or commercial performance
```

## P5 recursive gate

`tests/run_mc_noc_p5_gate.py` is the recursive qualification prerequisite for
the Phase-A closure workflow. It:

1. validates the exact closed V12 and P0-P4 source identities;
2. validates its public documentation contract and exact Verilator 5.050;
3. runs the P4 measurement/parameterization gate;
4. runs P3, P2, P1, and P0 targeted/parameter/static gates;
5. runs the V12 production recursive foundation gate;
6. rejects warning output and missing top-level PASS markers;
7. verifies closed source and repository containment after every child;
8. emits `MC_NOC_P5_LOGICAL_NOC_FREEZE_GATE=PASS` only after the full chain.

The generic gate emits `MC_NOC_P5_PHASE_A_CLOSURE_PREREQUISITE=PASS`; it does
not independently emit the final Phase-A closure marker. Only the outer
workflow may emit `MC_NOC_PHASE_A_CLOSED=YES` after the candidate, canonical
freeze, independent validation, guarded live apply, and post-live gate have all
passed.

The gate does not claim that a finite-drain test proves starvation freedom.
P1 sustained fairness is proved by P4's continuously eligible test; P2
sustained service remains proved by its closed adversarial regression.

## Phase-A closure and next seam

After the P5 candidate, frozen patch, independent validator, guarded live
apply, and live P5 gate all pass:

```text
MC_NOC_PHASE_A_CLOSED=YES
```

The next architecture work is Phase B, not a physical mesh and not coherence.
Repository evidence shows that the production aggregate line stream is still
internal to the single-cluster shared-L2 subsystem. Phase B must therefore:

1. expose the true post-local-fabric cluster line seam while leaving L2
   outside that cluster boundary;
2. prove single-cluster behavioral equivalence for loads, MSHRs, L1 fill,
   faults, stores, quarantine, peer conflicts, and reset;
3. only then compose multiple production clusters onto the frozen logical NoC
   for loads;
4. keep cross-cluster stores fail-closed until a separate coherence contract
   defines directory ownership, targeted invalidation, acknowledgments, and
   refill/store races.

This ordering preserves the closed logical transport while avoiding a second
NoC behind an already-private cluster L2.
