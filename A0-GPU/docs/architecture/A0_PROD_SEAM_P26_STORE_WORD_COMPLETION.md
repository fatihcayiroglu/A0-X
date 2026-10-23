# PROD-SEAM-P26 — explicit STORE_WORD completion and retry

P26 preserves frozen P25 and closes its accepted-vs-completed store-miss gap. P25 already ensures a no-write-allocate store-miss lane reaches the shared visibility-domain command boundary before commit acknowledgement; P26 now requires an explicit matching backend completion SUCCESS before P25 is allowed to observe that STORE_WORD as ready.

## Completion guard

`a0_store_word_completion_guard` captures one exact P25 STORE_WORD source payload and owns it until completion. Each issue carries an explicit `{write_id,retry}` attempt identity. Command acceptance changes the guard from ISSUE to WAIT_STATUS but does not raise source ready. A source acknowledgement pulse is generated only by a backend status with the exact live attempt id, `success=1`, and an unchanged source address/data payload.

A retryable failure below the configured retry bound increments the retry incarnation and reissues the exact captured 32-bit word address/data. The new attempt id is distinct from the failed attempt. A non-retryable failure or retry exhaustion enters a fail-closed terminal state: no source ready is synthesized, no further STORE_WORD is issued, and the upstream P25 commit therefore remains unacknowledged. P26 deliberately adds no recovery protocol yet.

Status with no live matching attempt is contained and diagnosed as a protocol error. The guard also diagnoses source valid withdrawal or payload mutation while a word is live. Same-cycle backend command acceptance plus matching SUCCESS is explicitly supported.

## Production composition

`a0_production_store_commit_completed_miss_visibility_subsystem` interposes the completion guard only on P25 command kind `STORE_WORD`. P23/P25 refill READ and durable WRITEBACK commands remain typed passthrough traffic and retain their pre-existing identity contracts. While the store guard is active, P25 remains on the held STORE_WORD transaction, so line traffic cannot bypass that visibility operation through this composition.

The wrapper adds `backend_cmd_store_attempt_id_o` plus explicit store-status inputs. Store command acceptance alone is insufficient to release the P25 miss lane; only the guard's matching SUCCESS pulse drives P25 backend ready for that STORE_WORD. Thus commit acknowledgement is completion-qualified rather than acceptance-qualified.

## Proven behavior

Directed qualification proves:

- exact STORE_WORD attempt payload remains stable under backend backpressure;
- command acceptance alone cannot acknowledge the held P25 source or production commit;
- retryable failure reissues identical address/data with a new attempt identity;
- matching SUCCESS is the only normal source-release event;
- command-accept + matching-SUCCESS in one cycle is handled correctly;
- stale/unknown completion status cannot release the source and is diagnosed;
- retry exhaustion fails closed without synthetic visibility success;
- end-to-end store-miss commit remains blocked until matching SUCCESS;
- backend memory updated at SUCCESS is observed by the next refill after commit acknowledgement;
- resident dirty-L2 hit commits bypass STORE_WORD completion exactly as in frozen P25;
- P23 refill READ and durable WRITEBACK typed traffic passes through unchanged;
- final normal-path diagnostics drain cleanly.

## Deliberate bounds

P26 is not a physical VRAM/DRAM controller and does not define when external media becomes persistent. It does not provide recovery from terminal STORE_WORD failure, ownership/snoop coherence, atomics, byte masks, globally atomic multi-lane stores, complete global memory ordering, or a formal memory-consistency model. Those remain later bounded milestones.
