# PROD-SEAM-P29 — safe STORE_WORD restart

P29 preserves the frozen P28/P27 implementation and adds a bounded restart boundary around it.
A failed commit is never converted into success. P28 must first complete its separate architectural
squash/abort handshake and enter `recovery_required`. Only while that state is live may the backend
assert `backend_store_status_reuse_safe_i`; an early reuse-safe assertion is deliberately not remembered.

The accepted safe condition creates a one-cycle local rearm/reset of the frozen P28 chain and toggles a
STORE_WORD-only backend-visible epoch remap. READ tags and WRITEBACK attempt IDs are not remapped. The
new STORE_WORD command therefore uses a backend-visible attempt identity distinct from the failed epoch,
including when `MAX_STORE_RETRIES=0`. A late status carrying the pre-recovery backend-visible identity
cannot be relabeled as the fresh post-recovery attempt. P29 is bounded to this restart contract and does
not claim physical VRAM persistence, full coherence, atomics, or complete global ordering.
