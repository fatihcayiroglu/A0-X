# A0 RTL9B-2 — L1 Memory-Service Integration

RTL9B-2 integrates the frozen RTL9B-1 direct-mapped L1 line-cache primitive
into the live memory-service boundary.

## Locked routing

- Legacy reads bypass the L1.
- Legacy stores bypass the L1 data path and are observed at physical request
  launch for conservative matching-line invalidation.
- MSHR line requests are the only cacheable client path.
- L1 misses use the existing external MSHR line backend request channel.
- External line responses enter the L1 before reaching the MSHR-facing
  response channel.
- Every backend line response is forwarded to the MSHR-facing client.
- Faulted, killed, and same-cycle-store-conflicting refills are not installed.

## Store launch

The core emits `service_legacy_req_valid` as a one-cycle physical request
launch pulse. A store observation is therefore:

`legacy_req_valid_i && legacy_req_write_i`

with `legacy_req_lane_mask_i` and `legacy_req_addr_i` carrying the physical
whole-wave store payload.

## Non-goals

RTL9B-2 does not add:

- write allocate
- dirty state
- writeback
- set associativity
- replacement metadata
- coherence
- TLBs
- L2
- NoC
- memory-controller logic
- atomics or fences

The existing RTL8C ordering, forwarding, store-queue, and physical-store
ownership rules remain authoritative.

## External contract

`a0_multi_wave_core` receives no new external ports. RTL9B-2 changes only
the internal boundary instantiation and source dependencies required to
compile the integrated L1.
