# PROD-SEAM-P15 — write-failure recovery / restart

P15 is a bounded successor to frozen P14. A P13 retry-exhaustion or terminal write failure is **not** converted into success and is **not** forgotten by an unconditional reset.

The successor captures the exact failed write incarnation and payload, blocks new store/refill admission, requests an architectural abort for the exact base write ID, waits for an explicit backend recovery-safe acknowledgement that pre-recovery late statuses can no longer appear, and waits for all already-accepted read transactions to drain. The original store source must also be quiesced/withdrawn after the architectural abort. Only then is frozen P14 reset for exactly one cycle and normal admission may restart.

This closes a recovery aliasing hole without claiming full coherence. P15 does not add dirty ownership, writeback, snoops, atomics, global memory ordering, or a DRAM/VRAM controller.

P15 never generates **synthetic success** during recovery.
