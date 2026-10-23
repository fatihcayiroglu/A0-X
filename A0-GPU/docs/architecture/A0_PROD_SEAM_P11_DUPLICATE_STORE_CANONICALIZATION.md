# A0 PROD-SEAM-P11 — Same-Commit Duplicate Store Canonicalization

## Scope

PROD-SEAM-P11 closes the bounded same-commit store collision gap left explicit in
P8.  P8 intentionally failed stop when two active lanes of one visibility commit
targeted the same 32-bit word because no winner contract had yet been frozen.  A
production implementation must not crash on that non-atomic lane race.  P11 adds
a local canonicalization stage before the frozen P10/P9/P8 chain.

The successor top is `a0_production_store_backend_collision_seam`; the bounded
primitive is `a0_store_commit_duplicate_canonicalizer`.  P10 and all earlier
milestones remain frozen predecessors.

## Deterministic local winner contract

For one visibility commit, each active lane is compared only with higher-numbered
active lanes in that same commit.  A lane is suppressed if any higher active lane
has the identical word address.  Consequently exactly the highest active lane for
each duplicated word remains in the canonical lane mask.

This policy is deliberately local and deterministic.  It matches the final value
that P8's pre-existing ascending-lane backend serialization would produce if the
fatal duplicate check were removed and every duplicate beat were emitted.  P11
therefore removes redundant writes without changing that natural final-writer
result.

All non-conflicting active lanes remain present.  Address and write-data payloads
are passed through unchanged; only losing duplicate lane-mask bits are cleared.
`store_duplicate_collapse_o` exposes whether at least one lane was collapsed on
each commit port while that commit is valid.

## Visibility and refill ordering preservation

P11 does not acknowledge a commit.  Canonicalized payload goes directly into the
frozen P10 seam, and upstream `ready` is the exact predecessor `ready`.  Therefore
P7/P8 visibility timing is unchanged: a successful commit still completes only
when the predecessor chain accepts its final canonical backend write at the real
external boundary.

Collapsing duplicate lanes does not weaken refill conflict detection because all
losing lanes share an address with a retained winner.  The set of distinct word
addresses is unchanged.  A conflicting refill therefore remains blocked until
that word becomes visible, while unrelated writes and refills keep predecessor
behavior.

## Directed proof

The P11 directed test creates one four-lane commit in which lanes 0, 2, and 3 all
store to the same word and lane 1 stores to another word.  Backend ready is held
low to prove the canonical command remains stable under backpressure.  The test
then proves only two backend write beats occur, the unrelated lane survives, and
lane 3 data is the visible winner for the triply-colliding word.

A subsequent line refill is issued through the complete frozen P10/P9/P8 read
path and returns the canonical winner and unrelated value from one modeled backing
memory.  Predecessor protocol diagnostics, read credits, and P10 generation state
must finish clean.

## Non-atomic semantics and bounded scope

P11 is **not** an atomic-memory guarantee and does not define ordering between
instructions, waves, CUs, clusters, or independent commit ports.  Programs that
require deterministic synchronization between competing writers still require an
atomic or stronger memory-ordering contract.  Highest-lane-wins is an
implementation-defined resolution for multiple lanes of one non-atomic visibility
commit only.

P11 does not add ownership/snoops, dirty/writeback state, atomics, global memory
ordering, backend write-completion acknowledgements, ECC/RAS, DRAM scheduling, or
physical VRAM controllers/partitions.
