# A0 PROD-SEAM-P8 — Unified Store-Commit / Refill Backend Visibility

## Scope

PROD-SEAM-P8 closes the bounded integration gap left by P7: successful P7
visibility commits and sliced-L2 refill reads now enter one explicit ordered
backend command domain.  P8 is a serialization/visibility seam.  It is not a
VRAM controller and does not add dirty state, ownership, snoops, writeback,
atomics, or a complete global memory-ordering protocol.

The production-shape composition is
`a0_production_store_backend_visibility_seam`; its arbitration/serialization
primitive is `a0_store_commit_line_backend_adapter`.

## Unified visibility point

The external backend command handshake is the visibility boundary:

- a store beat becomes visible when `backend_cmd_valid_o &&
  backend_cmd_ready_i && backend_cmd_write_o`;
- a refill read is accepted on the same command stream with
  `backend_cmd_write_o == 0`;
- a P7 visibility commit is acknowledged only when its **final active lane
  write beat** is accepted by that backend boundary.

Therefore P7 cannot release the successful store terminal before every active
lane of the commit has crossed the shared visibility point.

## Ordering contract

A refill whose line address conflicts with any pending commit is held behind
that commit.  A non-conflicting refill is allowed to make progress and may
interleave between beats of a multi-lane commit.  Store and refill selection
uses bounded round-robin state so a permanently active lower-numbered port is
not intended to monopolize the seam.

The line request side contains one registered request slot per refill port.
This is intentional: it breaks combinational ready/valid loops at the
P6/shared-L2 boundary, gives explicit finite buffering, and keeps request tag
and line-address identity stable under backend backpressure.

## Finite buffering and backpressure

Each refill input has exactly one registered pending slot.  The source sees
backpressure while that slot is occupied unless the resident request is being
accepted by the backend in the same cycle, in which case consume-and-replace
is legal.

One commit is active at a time.  Its lane mask, word addresses, and write data
are captured before the first backend beat and remain the authoritative
payload until the final beat is accepted.  The commit source must retain
`valid` until `ready`; dropping it early is a fail-stop protocol violation.

Zero-lane commits and duplicate active lanes targeting the same word are also
fail-stop in P8.  Duplicate-store-word ordering is deliberately left
unfrozen rather than silently inventing last-lane-wins semantics.

## Identity and response contract

Refill identity is not reconstructed from address or payload.  The adapter
prepends the selected line-port/slice identity to the existing network tag on
the backend read command.  Backend responses decode that explicit port field
and return the original network tag, line address, fault bit, and line data to
the same refill port.  An out-of-range returned port field raises
`backend_resp_protocol_error_o`.

Backend fault provenance is independent of store visibility state.  A
faulting P7 store does not create a successful visibility commit, while a
faulting refill response retains its original read tag and fault status.

## Causal visibility proof

The directed P8 test models backing memory at the unified command boundary.
A P7 store becomes pending, a conflicting P6 load is held, the successful
store response creates a commit, and the backend is intentionally
backpressured.  The commit payload remains stable and the P7 terminal remains
held.  When the backend accepts the store beats, the modeled memory is updated
on those exact write handshakes.  Only after the final beat does P7 acknowledge
the commit; the previously blocked load can then enter the refill path and
must return the newly committed values from that same modeled memory.

The same test also proves non-conflicting refill progress, commit-port
round-robin progress, refill tag/fault provenance, and faulting-store
no-commit behavior.

## Bounded scope

P8 does **not** claim full coherence.  Later milestones still own dirty state,
writeback, ownership/snoops, atomics, stronger global ordering, real VRAM
controllers/partitions, QoS, ECC/RAS, and wider memory-system performance
qualification.
