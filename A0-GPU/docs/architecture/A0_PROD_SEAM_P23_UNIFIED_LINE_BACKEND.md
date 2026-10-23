# PROD-SEAM-P23 — Unified line backend command seam

P23 composes the frozen P22 multi-client, multi-slice recoverable dirty L2 with a single bounded backend command stream. It does **not** introduce a VRAM controller, memory scheduler, ownership protocol, or full global memory ordering.

## Contract

* Refill reads and durable writebacks share one fair round-robin command boundary.
* A read command carries explicit `{home_slice, global_requester_tag}` identity. Requester identity is never reconstructed from address or payload.
* A write command carries the existing opaque durable writeback attempt id. Read-response identity and write-status identity remain separate typed return paths.
* A one-entry registered command hold keeps command type, identity, address, and write data stable while the physical backend applies backpressure.
* A separate registered writeback input decoupler prevents a combinational `valid`/`ready` loop between the frozen P20/P22 writeback producer and the P23 arbiter.
* Arbitration is bounded round-robin across all slice refill-read sources and the writeback source. A continuously requesting source cannot be bypassed indefinitely by another continuously requesting source.
* Invalid read-response home-slice encodings are contained and raise the public protocol diagnostic; they are not routed to a requester.
* Dirty replacement keeps the P22 durability contract: replacement refill does not issue until the exact dirty victim receives durable writeback `SUCCESS`.
* Out-of-order durable writeback status only releases its exact slice/attempt; peer slices retain independent progress.

## Deliberate bounds

P23 leaves P22's store input slice-local. It does not yet connect the earlier production physical-store commit stream to all dirty-L2 home slices. It also does not claim a physical VRAM controller, DRAM timing, bank scheduling, QoS, ECC, atomics, snoops, dirty ownership between agents, or complete global memory ordering. Those remain later bounded production milestones.
