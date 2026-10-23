# PROD-SEAM-P27 — bounded STORE_WORD status timeout

P27 freezes canonical P26 and closes one bounded liveness hole: after a P26 `STORE_WORD` command is accepted, a backend that never returns a matching status could otherwise keep the production visibility commit blocked forever without a terminal classification.

## Timeout contract

`a0_store_word_status_timeout_guard` tracks exactly one accepted P26 store attempt identity. A real matching status is forwarded unchanged to frozen P26. A stale or unknown status is contained, diagnosed, and cannot reset the live timer or release the source.

Each accepted attempt receives a fresh `STATUS_TIMEOUT_CYCLES` window. If no matching real status exists on the deterministic deadline cycle, P27 injects only an explicit **non-retryable failure status** for the exact live attempt. This is a local timeout classification and is never converted into success; it is not a backend success or a durability claim. Frozen P26 therefore enters its existing terminal fail-closed state; the held visibility commit remains unacknowledged.

A matching real status on the deadline cycle has priority over timeout. Same-cycle command acceptance plus matching status remains legal. A retryable status that causes frozen P26 to reissue with a new attempt incarnation starts a fresh timeout window for that new command acceptance.

P27 exposes live timer state, current age, a one-cycle timeout pulse, and a sticky timeout-seen diagnostic. Late status after timeout is not forwarded into frozen P26 and is diagnosed as a protocol error.

## Production composition

`a0_production_store_commit_timed_miss_visibility_subsystem` wraps frozen P26 without modifying it. It monitors only typed `STORE_WORD` command handshakes and filters/injects only the store-status channel. P23 refill READ and durable WRITEBACK commands/statuses remain connected through the frozen P26 composition and are not timed by P27.

## Proven behavior

Directed qualification proves:

- frozen P26 READ/WRITEBACK/store-success behavior remains intact;
- accepted STORE_WORD with no status times out into terminal fail-closed state;
- timeout never generates source ready or commit acknowledgement;
- one timed-out attempt produces exactly one timeout pulse;
- late status after timeout is contained and diagnosed;
- matching SUCCESS on the deadline cycle wins over timeout;
- a retryable failure followed by a reissued attempt receives a fresh timeout window;
- repository and frozen P26 predecessor identities remain unchanged.

## Deliberate bounds

P27 does not implement terminal STORE_WORD recovery because the P26 boundary does not yet carry enough architectural commit-port abort/squash identity to do that safely. P27 is not a physical VRAM/DRAM controller, does not prove media persistence, and does not add ownership/snoops, atomics, byte masks, globally atomic multi-lane stores, or a complete global memory-ordering model.
