# A0 PROD-SEAM-P9 — Backend Read Transaction Integrity

## Scope

PROD-SEAM-P9 closes the bounded response-integrity gap left by P8. P8 creates
one ordered store-commit/refill backend command boundary, but an accepted read
still needs an explicit lifetime from backend command acceptance through exactly
one matching completion. P9 adds that lifetime without adding dirty state,
ownership, snoops, writeback, atomics, or a VRAM controller.

The production-shape successor is
`a0_production_store_backend_transaction_seam`; its bounded lifecycle primitive
is `a0_backend_read_transaction_guard`. The frozen P8 seam remains the upstream
producer and visibility point.

## Command probe and visibility preservation

P9 deliberately does not combinationally feed P8 command fields back into P8
`ready`. The incoming P8 command is first captured in a one-entry non-handshaking
probe register. While the probe is occupied, P8 must hold the exact command
stable. P9 asserts P8 `ready` only on the same cycle that the probed command is
actually accepted by the external backend.

This registered probe breaks the P8/P9 command-ready combinational loop without
moving the P8 store-visibility boundary earlier. A store commit therefore still
becomes acknowledged only when its exact backend write beat is externally
accepted, not merely when P9 snapshots it.

## Finite outstanding read contract

Accepted read commands consume one of exactly `READ_TRACK_COUNT` scoreboard
entries. Each live entry stores the complete backend read tag and line address.
The tag already contains the P8 line-port/slice identity plus the original
network tag, so requester identity is never reconstructed from payload data.

When no entry is free, a read probe remains pending and external read command
issue is backpressured. Writes do not consume read scoreboard entries. Reuse of
a backend read tag that is already live is also held until the original
transaction completes. This is intentionally stricter than allowing same-tag
transactions to coexist at different addresses and prevents response aliasing.

The exported `read_outstanding_o`, `read_capacity_full_o`, and
`read_duplicate_block_o` signals make the bounded credit state observable.

## Response integrity contract

A backend response is forwarded upstream only if it is one of:

1. an exact match to a live scoreboard entry by backend tag and line address;
2. a legal zero-latency/same-cycle response to the read command accepted in that
   same cycle, with the same tag and line address.

An accepted exact response frees its live entry exactly once. Out-of-order
responses are legal because each completion searches the live transaction set
and restores the stored identity belonging to that transaction.

Unknown tags, duplicate responses after an entry has already completed, and
address mismatches against a live tag do not become P8 refill responses. They
raise `read_resp_protocol_error_o`, which is combined with P8's pre-existing
backend protocol diagnostic at the production seam. An address-mismatched
response does not consume the live entry; a later exact completion remains
legal.

Backend fault provenance is independent of transaction-integrity diagnostics.
An exact live response with `backend_resp_fault_i=1` is still the completion of
the right transaction and preserves that fault bit upstream. A protocol error
never masquerades as a backend faulting refill.

## Directed proof

The P9 directed test fills the finite scoreboard with two independent reads and
proves a third read cannot reach the backend until credit is released. It then
completes the two live reads out of order and checks exact slice/network-tag,
line-address, data, and fault restoration.

The same test proves capacity-release progress, duplicate-response rejection,
line-address-mismatch rejection without losing the live transaction, a later
exact completion, unknown-response rejection, fault provenance, live-tag reuse
backpressure, and safe reuse of that tag only after completion.

## Bounded scope

P9 is a read-transaction integrity and credit milestone. It does **not** claim
full coherence, global memory ordering, dirty/writeback ownership, atomics,
ECC/RAS recovery, DRAM scheduling, physical VRAM partitioning, QoS, or memory
controller timing. Those remain later bounded milestones.
