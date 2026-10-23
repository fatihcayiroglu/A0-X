# A0 PROD-SEAM-P14 — Backend Write Status Timeout Watchdog

## Exact-attempt watchdog contract

P14 wraps the frozen P13 production retry seam without changing it. Every accepted external write attempt arms one bounded status watchdog for the exact P13 attempt ID. Read issues do not arm the watchdog.

## Timeout-to-retry conversion

If the exact live write attempt receives no exact backend status for `STATUS_TIMEOUT_CYCLES`, P14 emits exactly one synthetic status for that exact attempt with `success=0,retryable=1`. P14 can never synthesize success, so it cannot release P12/P13 store visibility. Frozen P13 remains the authority that increments the retry incarnation and eventually reaches its bounded retry-exhausted fail-closed state.

## Real status precedence and provenance

A real exact backend status on the timeout boundary wins over timeout synthesis. Real statuses are forwarded verbatim. Stale, unknown, duplicate, or malformed real statuses are not hidden and do not reset the watchdog; they continue to reach frozen P13 so its existing protocol diagnostics remain authoritative.

## Retry isolation

Each newly accepted retry incarnation arms a fresh watchdog. A timeout event clears only the watchdog for the current exact attempt. Late status from an older attempt cannot cancel the new watchdog because attempt identity is compared exactly.

## Frozen predecessor preservation

P13 and all earlier seams remain immutable. P14 instantiates `a0_production_store_backend_retry_seam` directly and inserts only the status watchdog around its external write-status boundary. Read identity/fault provenance, write payload, retry count, anti-ABA rules, and visibility release semantics remain predecessor-owned.

## Directed proof

The directed test proves same-cycle exact status, stale-status non-reset, lost-status synthetic retryable failure, exactly-once timeout, no synthetic success, retry-watchdog rearm, real retryable preservation, exact real status precedence at the timeout boundary, unknown-status pass-through, and no idle spurious timeout.

## Bounded scope

P14 detects and converts lost write status into bounded P13 retry progress. It does not recover a write after P13 retry exhaustion or terminal failure, add ECC/RAS policy, dirty/writeback coherence, ownership/snoops, atomics, global ordering, VRAM scheduling, or a throughput write queue.
