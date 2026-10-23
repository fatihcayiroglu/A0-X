# P37 logical memory channels: development design and proof scope

Status: **BEHAVIOR_VALIDATED_DEVELOPMENT_NOT_CLOSED**. Reviewed on 2026-10-18.
Three component variants and three integrated variants completed native
development simulation; each integrated variant passed all 22 scenarios. Both
mutation fixtures were detected by semantic assertions. The source/log-bound
receipts below establish this bounded test coverage, not canonical qualification
or phase closure.

## Source boundary and predecessor

The candidate adds `rtl/memory/a0_memory_channel_scheduler.sv` and
`rtl/memory/a0_production_atomic_channel_subsystem.sv`. The wrapper composes the
existing `a0_production_atomic_fenced_subsystem` as `u_p36` with the scheduler as
`u_channels`; the P36 child and its dependent source are unchanged.

The separately generated `../../../P37-PREDECESSOR-CONTAINMENT.json` relative
to this document is a read-only byte-containment receipt. It compares every one
of the 441 extracted predecessor files with `P36-ARCHIVE-INTEGRITY.json`, using
SHA-256 and byte length, with zero baseline exclusions. It establishes
441/441 matches for that extracted subset. It does not establish fresh P36
behavior, native filesystem modes, full archive rehydration, or qualification.
Generated root `xsim.dir` files and simulator logs are outside that baseline and
do not change the predecessor-source conclusion.

## Logical command ownership

The scheduler consumes the unchanged single ready/valid backend stream:
READ=`00`, WB=`01`, STORE=`10`. Kind `11` is not accepted and raises the sticky
channel protocol diagnostic. At most one input command is accepted per cycle.

Each channel has `DEPTH_PER_CHANNEL` slots and an independent FIFO containing
slot indices. Slot states are FREE, QUEUED, ISSUED and RETURNED. Acceptance
allocates a free, unexhausted slot and copies the complete command. Dispatch
removes its index from the FIFO but retains its ownership; an accepted return
buffers its result in that same slot. Only actual typed upstream delivery frees
the slot. Neither enqueue nor dispatch manufactures a completion.

The defaults are four channels, two slots per channel, eight 32-bit words per
line and eight transport-generation bits. Counts and identity widths must be
positive; line words must be a power of two. Derived address/token widths must
match their definitions. Initial assertions reject inconsistent geometry.

Each channel dispatches at most one command per cycle, in acceptance order for
that channel. Different channels can dispatch concurrently. A stalled channel
holds all command fields stable and does not block already accepted work in
other channels. The shared input still has head-of-line blocking if its offered
destination is full. It cannot bypass that offer. A slot freed by delivery in
the current cycle becomes available on a later cycle; speculative same-edge
reuse is not performed. Recycled physical slot indices must not change FIFO
order.

## Address mapping and exact response identity

Addresses at this boundary are word/line addresses, not byte addresses.
`WORD_SELECT_W = log2(LINE_WORDS)` (zero for a one-word line), and
`LINE_ADDR_W = 32 - WORD_SELECT_W`.

- READ and WB use the supplied line address.
- STORE derives its canonical line from `store_word_addr >> WORD_SELECT_W`.
  The inherited STORE command's line field is ignored, including its normal
  zero value.
- Destination channel is the unsigned canonical line modulo `CHANNEL_COUNT`.
  Channel count is independent of the inherited cache slice count.

Every dispatch carries the canonical line, the full data payload, STORE word
address and data, operation kind, all three inherited identity fields, and a
new transport token. Token layout is `{generation, slot_index}`. Channel is
also part of ownership through the physical response lane.

A valid return must echo the full token, kind, READ tag, WB attempt ID, STORE
attempt ID, canonical line and STORE word address exactly. Even fields unused
by that operation must match the dispatched value. No truncation to a local
tag, slot index or low address bits is allowed. This added token does not
replace the inherited identities or imply an added generation field in P36's
READ identity.

All channel return lanes can be accepted concurrently. A response is legal for
an ISSUED owner, or for the precise QUEUED head that dispatches on the same
edge. An early return for other queued work is rejected. Stale, duplicate,
wrong-channel and mismatched responses are consumed with a rejection pulse;
they do not free the live owner or produce an upstream completion. A later
correct response can still finish that preserved owner.

## Buffered return arbitration and accounting

One total buffered result is delivered upstream each cycle, using round robin
over all `CHANNEL_COUNT * DEPTH_PER_CHANNEL` slots. This serializer matches the
inherited typed return pulses, which have no return-ready handshake. A
continuously buffered result has a scheduling bound of that many service
cycles. This is a local buffered-return bound, not an end-to-end memory or
ingress-liveness guarantee. The external controller can stall dispatch or
withhold a result indefinitely.

READ returns data, tag, line and `fault = !success`; its retryable input is not
used. WB and STORE forward their exact attempt ID, success and retryable flags.
The slot remains owned during the delivery cycle.

`busy_o` accounts for every QUEUED, ISSUED and RETURNED slot and every current
raw input/return offer, including unsupported or invalid offers.
`quiescent_o` is the inverse. Per-kind and per-channel busy signals account for
corresponding owned work and offers. Exhausted tokens alone are not live work.
Raw invalid traffic can delay drainage while it is being offered; historical
diagnostics alone cannot do so.

`response_rejected_o` is a registered per-channel pulse. `protocol_error_o` in
the scheduler is sticky until reset and is exposed separately by the wrapper
as `channel_protocol_error_o`. The wrapper preserves this diagnostic without
OR-ing it into the P36 child's protocol error or the transport-safe predicate.
After a malformed packet is rejected and all real ownership drains, transport
quiescence may become true while this diagnostic remains high. A rejected
packet must not permanently poison an otherwise safely drained transport.

## Finite tokens and explicit rearm

Each channel/slot maintains its own monotonically allocated generation,
starting at zero. Allocating the maximum generation exhausts that slot for
future allocations without cancelling its current owner. Generations never
silently wrap. The channel exhaustion output ORs its slot flags; other
unexhausted slots in that channel remain usable.

Rearm requires an explicit external all-generation certificate, every slot
FREE, no raw return offers and at least one exhausted slot. That certificate
must cover every external old-token copy, not just the scheduler's empty local
tables. All slot generations then reset to zero, with a pulse identifying
previously exhausted channels.

An unaccepted input offer may remain held during this rearm. Input ready is
forced low for the rearm cycle, and the held offer may be accepted in the next
cycle. This deliberate acceptance bubble avoids an exhausted-token deadlock
without mixing a new owner with the generation reset. It is distinct from the
wrapper's stricter recovery gates, which require public transport quiescence
including raw ingress offers. Owned work or any raw return always blocks token
rearm, even if the external certificate is asserted.

State reset is synchronous and active-low, matching the inherited P36 contract;
it is sampled on the rising clock edge. Handshake outputs remain gated while
reset is low. Reset discards ownership and token history. System reset must also reset or
drain the external transport so pre-reset responses cannot return into reused
tokens. The scheduler does not itself prove that external contract.

## STORE timeout and conservative recovery

The unchanged child starts STORE timeout at the upstream backend handshake,
which is now scheduler enqueue. Queue residence and channel stall time therefore
consume that timeout. A timed-out STORE remains a real QUEUED/ISSUED/RETURNED
transport obligation until its actual late response is delivered. Timeout
does not cancel a slot, acknowledge an unperformed memory write, or grant a
reuse certificate. A late status may drain transport while the inherited child
rejects it as architectural success for the aborted attempt.

The wrapper defines `transport_safe` from scheduler quiescence. It ANDs this
global predicate with the external STORE status-reuse certificate, STORE
all-generation certificate, WB recovery valid/ready handshakes, and atomic
epoch/all-generation quiescence inputs. Thus even unrelated queued, issued or
buffered channel work blocks these recovery certifications. This is deliberately
conservative and can reduce progress relative to a proven per-kind/per-slice
gate. The exposed per-kind busy signals do not weaken that global gate.

Scheduler token rearm receives the explicit channel all-generation certificate
and applies its own owned-slot/raw-return checks, as described above. Local
emptiness never substitutes for the external historical-copy certificate. There
is no cancellation protocol; if a controller loses a real response permanently,
the corresponding ownership and recovery blockage remain unresolved.

## Fence publication around the unchanged P36 child

The P36 child continues to own the admission cut, enrolled STORE payloads,
architectural atomic retirement, current errors and its stable response tuple.
The wrapper holds the child in RESPONSE while successor transport drains.

`fence_publish_q` becomes set only after the child has a valid response and the
transport is safe. Once published, external fence valid remains asserted until
the external ready handshake; the child response is consumed on that same
handshake. A new rejected raw packet cannot retract an already published valid
or change its tuple while it is backpressured. This adds transport drainage to
publication without editing the child's fence admission or completion logic.
Dirty resident data alone still does not require a flush or durability promise.

## Component test matrix and completed runs

Source: `tests/rtl/a0_memory_channel_scheduler_tb.sv`. All three configurations
passed in standalone native simulation. Receipts are
`component-evidence/standalone-v{0,1,2}-4/result.json`, relative to the development
checkpoint root. Accepted/dispatched/returned/delivered counts all agree:
18/18/18/18 for variant 0, 31/31/31/31 for variant 1, and 50/50/50/50 for variant 2.

| VARIANT | Channels | Slots/channel | Words/line | Token generation bits | Status |
|---|---:|---:|---:|---:|---|
| 0 | 1 | 1 | 1 | 2 | PASS |
| 1 | 2 | 2 | 2 | 2 | PASS |
| 2 | 4 | 3 | 4 | 2 | PASS |

The completed runs exercised the following checks:

| Check group | Coverage | Applicable variants |
|---|---|---|
| Mapping, FIFO, full and stable | Exact payload/identity, full destination, stalled stability, acceptance conservation | 0/1/2 |
| Independent channel dispatch | Accepted ready-channel work progresses while channel zero is blocked | 0/1/2; concurrency witness in 1/2 |
| Recycled-slot FIFO and out-of-order return | New allocation into a freed slot cannot overtake older queued work | 1/2 |
| Backing memory STORE mapping | Real model WB, every STORE word in the line, later READ data | 0/1/2 |
| Concurrent returns and bounded fairness | Same-type concurrent returns plus mixed-type serialized completions | 0/1/2; concurrency witness in 1/2 |
| Same-edge dispatch/return and early rejection | Preserve queued ownership, reject early return, accept dispatch-edge echo, deny unsafe rearm | 0/1/2 |
| Full-width addresses and identities | High address/identity bits remain exact; finite backing model projects only storage address | 0/1/2 |
| Exact response identity and stale rejection | Corrupt each identity field, correct completion, duplicate, stale token after slot reuse | 0/1/2 |
| Invalid ingress | Kind 11 is unaccepted, visible in busy, and diagnosed | 0/1/2 |
| Synchronous reset boundary | An off-edge pulse preserves an issued owner; held reset clears state on sampled edges | 0/1/2 |
| Finite generation and held-request rearm | Exhaust every token, reject early certificate/raw old return, acceptance bubble, held offer resumes | 0/1/2 |

Every positive receipt records the final
`PROD_SEAM_P37_SCHEDULER_BEHAVIOR=PASS variant=N` marker, nonzero completed
operation counts, and normal HDL finish. Raw logs and exact source hashes are
retained. A source-text marker alone would not establish execution.

## Integrated test matrix and 22 completed scenarios

Source: `tests/rtl/a0_production_atomic_channel_subsystem_tb.sv`. The driver
uses a finite memory model with actual READ data, WB line contents and STORE
word updates. Its internal `phy_*` variable names describe this logical model;
they do not implement or verify a physical memory PHY.

| VARIANT | Cache slices | Channels | Slots/channel | Words/line | Status |
|---|---:|---:|---:|---:|---|
| 0 | 1 | 2 | 3 | 1 | PASS |
| 1 | 2 | 1 | 3 | 2 | PASS |
| 2 | 4 | 4 | 3 | 4 | PASS |

Each completed run used two clients, two STORE commit ports, two lanes per port,
eight channel-generation bits and a 512-cycle STORE timeout. Variants 0 and 1
exercise slice/channel count mismatch. The 22 scenario names come from the
actual `mark(...)` calls (the timeout loop emits two separate scenarios):

| ID | Executed scenario | Status in all three variants |
|---:|---|---|
| 1 | EMPTY_FENCE_EXACT_RESPONSE | PASS |
| 2 | DIRTY_RESIDENT_DRAIN_NOT_FLUSH_AND_LATER_EXACT_WB | PASS |
| 3 | OUTSTANDING_READ_DELIVERY_DRAINS_FENCE | PASS |
| 4 | SAME_EDGE_READ_DELIVERY_AND_FENCE_CUT | PASS |
| 5 | SAME_EDGE_ALL_STORE_PORTS_CAPTURE_AND_NEW_ADMISSION_BLOCK | PASS |
| 6 | CAPTURED_FULL_STORE_PAYLOAD_AND_BACKEND_PROMISE_BACKPRESSURE | PASS |
| 7 | LIVE_WB_EXACT_PAYLOAD_AND_SAME_EDGE_STATUS_CUT | PASS |
| 8 | HELD_ARCHITECTURAL_RETIRE_AND_SAME_EDGE_RETIRE_CUT | PASS |
| 9 | MIXED_PUBLIC_READ_WB_STORE_AND_HELD_ATOMIC_RETIRE | PASS |
| 10 | MULTIPLE_STORE_PORTS_INDEPENDENT_TERMINAL_ACCOUNTING | PASS |
| 11 | STORE_ABORT_FAULT_BACKPRESSURE_SELECTIVE_REARM | PASS |
| 12 | READ_FAULT_AND_ATOMIC_FAULT_REQUIRE_REAL_DELIVERY_RETIRE | PASS |
| 13 | WB_TERMINAL_FAILURE_RETAINED_PAYLOAD_AND_RECOVERY_DRAIN | PASS |
| 14 | HELD_FENCE_RESPONSE_IDENTITY_AND_ALL_YOUNGER_DOMAINS_BLOCKED | PASS |
| 15 | P37_CHANNEL_STALE_STORE_STATUS_CANNOT_RELEASE_FENCE | PASS |
| 16 | INVALID_MODE_EXACT_ERROR_AND_FRESH_FENCE_IGNORES_HISTORY | PASS |
| 17 | FULL_RETIRED_TABLE_NOT_LIVE_WORK_AND_POST_FENCE_NAMESPACE_PROGRESS | PASS |
| 18 | QUEUED_STORE_TIMEOUT_LATE_STATUS_AND_SAFE_RECOVERY | PASS |
| 19 | ISSUED_STORE_TIMEOUT_LATE_STATUS_AND_SAFE_RECOVERY | PASS |
| 20 | STORE_RETRYABLE_FAILURE_EXACT_RETRY_AND_FENCE | PASS |
| 21 | WB_RETRYABLE_FAILURE_EXACT_PAYLOAD_RETRY_AND_FENCE | PASS |
| 22 | STALE_PACKET_AFTER_FENCE_PUBLICATION_CANNOT_RETRACT_VALID | PASS |

The driver independently counts channel commands/returns and inherited
architectural acceptance/delivery/retirement/abort/recovery. Every variant
completed the final `P37_INTEGRATED_PASS variant=N scenarios=22 ...` marker and
normal HDL finish. The three receipts are
`integration-evidence/standalone-behavior-3-v{0,1,2}/result.json`, with 66 scenario
executions in total. The backing-memory model changes data only on actual
channel responses; queued or issued obligations cannot manufacture completion.
The current monitor additionally compares upstream READ data with an independent
snapshot of the actual physical-model return, checks identity bounds before
indexing, and checks channel busy/quiescence, certificate masking, generation
and diagnostic invariants. The three integrated XSIM runs total 145,977 checks.

## Negative witnesses and remaining qualification

Two single-change mutation fixtures were built and executed with the same
component testbench: `p37_wrong_store_route` replaces STORE canonicalization
with the ignored input line, and `p37_false_quiescence` forces quiescence high.
Both compiled successfully and then triggered the semantic assertion
`P37 public busy/quiescence accounting mismatch` at 56 ns. The wrong-route
fixture violates the reference per-channel ownership accounting; the
false-quiescence fixture violates public quiescence accounting. The raw runs
remain FAIL, and the collector classifies them as DETECTED negative witnesses.
They are not positive DUT passes. A build failure, engine crash or timeout alone
would not count as mutation detection.

Raw receipts are
`component-evidence/standalone-p37_{wrong_store_route,false_quiescence}-4/result.json`.
The collector `component-evidence/standalone-component-behavior-4.json` binds
both exact fixture edits to the current scheduler, verifies source/log hashes
and records the observed assertions.

The native runtime workaround uses `tests/run_prod_seam_p37_development.py
--standalone` to execute the generated simulation executable directly, with
its required runtime library search directories supplied only to that process.
The workspace compiler overlay remains recorded and unchanged. Installed tool
files and operating-system settings were not edited. Earlier interactive xsim
startup failures and the independent failing trivial control are historical
records; the completed standalone runs supersede the earlier unproven
behavioral status.

Actual execution exposed two testbench issues that were corrected before the
final runs. Per-lane `#1` delays were removed from component response preparation
so concurrent response batches do not cross a sampling edge. A string-valued
conditional expression selecting an integrated scenario label was replaced
with equivalent explicit `if/else` calls to avoid an XSIM generated-code crash.
Neither correction changed the scheduler or wrapper RTL.

A subsequent native Verilator check found six implicit line-address extensions
inside component-testbench modulo operations. Explicit unsigned 32-bit casts
now express those extensions. The three component configurations and both
mutations were rerun after this testbench-only correction; the integrated
sources and their valid receipts were unchanged.

The subsequent strict-cleanup revision changed P37 sources: four nonnegative
indices now have bounded widths; scheduler reset follows P36's synchronous
contract; transport safety requires quiescence and no typed busy state. The
component scoreboard is an ordered clocked testbench task with its original
blocking same-edge updates and post-NBA check. Initial values are explicit,
unused parameters removed, and driver bounds/exhaustion checks strengthened.
All affected component, integration and mutation cases were freshly rerun.
Frozen predecessor files remain byte-identical.

A fresh P36 drain-fence controller smoke also completed 14 scenarios and 172
checks, with receipt
`native-recovery/continuation-20261015/p36-standalone-1/result.json`. It uses its
recorded earlier runner revision, unchanged during that run. This limited
controller/variant smoke is not full predecessor requalification.

The runner retains invocations, tool versions, raw stdout/stderr, source hashes
before/after, normal finish and pass-marker checks. XSIM build warnings remain
visible in the raw logs and indexed receipts. This is native development evidence and does
not satisfy the inherited exact Verilator 5.050 or canonical zero-warning
contract. No warnings were suppressed for these runs.

The source-built Windows Verilator now passes all three component and all three
integrated strict lint checks without RTL warnings/errors. Native behavioral
runs also pass all six positive cases, and both semantic mutants are detected
after clean generation/build. Public transaction counters agree with XSIM;
native integrated runs also total 66 executions and 145,977 checks. The native
audit binds these results and the synchronous-reset witness.
Its actual version metadata remains `rev vUNKNOWN-built20261016`, despite the
verified v5.050 source archive. This is development evidence, not the exact
canonical tool. Earlier failed lint/timing experiments remain historical.

`../../../P37-DEVELOPMENT-STATUS.json` indexes current and historical receipts
with separate source bindings. The 18 October package's root
`P37-DEVELOPMENT-VALIDATION.json` is the XSIM behavioral evidence audit;
`P37-NATIVE-DEVELOPMENT-VALIDATION.json` is the separate native behavioral/lint audit;
the earlier static-only validation is retained as
`EVIDENCE/historical-static-validation-20261015.json`. Raw evidence paths in the
bundle are placed below `EVIDENCE/`.

Fresh full predecessor qualification, exact canonical simulation, strict raw
accounting and suppression checks, complete containment, native rehydration
and publication checks remain necessary before phase promotion. P37 remains
open and P38 has not started.

These completed tests establish logical memory-channel behavior within the
listed configurations and scenarios. They do not establish GDDR/HBM signalling,
vendor timing, refresh, bandwidth, durability, timing closure, PPA,
FPGA/silicon operation, large-CU scaling, GPU workload performance or superiority
to any commercial graphics card.
