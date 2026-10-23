# P35 — cache-backed atomics and replay retention

Status: implemented in external staging with measured development simulations;
NOT promoted, canonically qualified, packaged, or CLOSED. Development evidence
and its independent raw audit are listed below; they are not canonical proof.
Frozen P34: `018a06006a957f3edb2884ccc9df5f1447d824bbc1c3a6a916431b5923c44390`,
300441330 bytes, manifest 5096/5096. All P34/predecessor source remains unchanged.

## Visibility and serialization boundary

The staged production wrapper adds one atomic controller to the actual P34
cache-backed coherence hierarchy. The controller owns the probe/reclaim port;
external remote-probe arbitration is not part of this bounded composition.
All atomic sources enter one ready/valid stream carrying an explicit source ID.
One active operation provides a unique serialization point for each location
(and deliberately serializes different locations too). This is not a throughput
claim for distributed atomics, independent cache domains, or 200+ CUs.

A dedicated extra P34 READ client fills cold lines. Its existence changes the
physical backend requester tag width at client-count power-of-two boundaries;
the wrapper must expose that width rather than silently truncate identity.
READ completion is a residency aid only, never the value used for an atomic.
The controller acquires a real TAKE response and uses that latest complete line.
A TAKE miss has no ownership/data; it must cause another READ/TAKE attempt.
Raw TAKE cannot remain offered while its own filling READ needs admission.

P34 orders earlier accepted READs and raw/captured STOREs before TAKE. Accepted
TAKE owns the full set until exact reclaim, blocking alias/exact READ/STORE.
The RMW operates privately on those accepted bytes. Its linearization point is
the exact reclaim handshake installing the entire updated line in real cache.
No successful atomic result may precede that edge. The P34 ownership generation
is separate from the atomic request generation; home/node/line/ownership-token
must all match. STORE-only recovery never resets the atomic controller/ledger.

Raw normal STORE has P34 priority over an unaccepted TAKE. Continuous conflicting
traffic can starve this bounded controller; no fairness/liveness bound is claimed.
Future scalable integration needs per-home serialization and explicit admission
fairness, not multiple uncontrolled serializers for one address.

## Request identity and finite retained results

Key: `{source, context, request_id, generation}`. Immutable descriptor:
`{word_address, is64, opcode, operand, compare_operand}`. Same key with changed
descriptor is rejected without replacing the original record or touching cache.
An exact committed retry returns the original saved value/CAS outcome, never
reacquires the line and never applies the side effect again. Pending retries
are backpressured. A held response must remain entirely stable.

Finite entries remain committed after response acceptance. Response-ready is
not a retry-quiescence certificate. A full ledger backpressures new identities
while committed retries remain serviceable. The first successor uses one
conservative GLOBAL generation namespace, not independent context reclamation.
Only an idle controller with no offered request/held result may accept epoch
advance. A newly observed LOW then HIGH current-epoch-quiescent certificate is
required; wrap additionally needs fresh all-generations-quiescent certification.
Advancing clears the atomic ledger only, not cache, READ, WB, STORE or P34
ownership allocation. Wrong-generation requests are rejected. Finite same-value
generation reuse ultimately relies on the truthful all-old-copies certificate;
no finite tag can distinguish a maliciously delayed identical tuple after that.

The certificate authority must include requester retry buffers, response copies
and all transport state. It cannot merely inspect controller busy. Architectural
requesters must retire a transaction once by identity even if a lost-response
retry legitimately produces another response packet.

## Operations and data preservation

Opcodes 0..10: exchange, compare-exchange, add, subtract, signed minimum,
signed maximum, unsigned minimum, unsigned maximum, AND, OR, XOR.
Both 32-bit and naturally aligned 64-bit operands are supported by the staged
implementation. Word addresses are 32-bit; 64-bit values use low word then high
word (little-endian), wholly inside one power-of-two cache line. A one-word line
must explicitly reject 64-bit requests; no two-line atomicity is implied.
Arithmetic is modulo the selected width; signed comparisons use that width.
All untouched words remain byte-for-byte intact. Failed CAS preserves original
bytes and dirty responsibility. Modified data must remain dirty until real WB;
reclaim is visibility, not external-memory durability or a system fence.

## Architectural retirement boundary

The raw `a0_production_atomic_coherent_progress_subsystem` exposes transport
responses, including repeated committed results. Its successor composition,
`a0_production_atomic_retiring_subsystem`, places a real synthesizable
`a0_atomic_response_retire_guard` between transport and architectural retirement.
The guard retains finite FREE/ISSUED/RESULT_READY/RETIRED entries. Retired entries
are tombstones, not immediately free slots. An exact issued key and descriptor
are required before any response can become a result. Identical duplicates are
consumed and classified without a second retirement; differing result, fault or
CAS-success fields are rejected. Unknown and wrong-generation packets are
rejected. Backpressured retirement holds one selected entry and its full payload.

Request acceptance requires simultaneous availability in controller and guard.
Descriptor collisions and wrong epochs cannot enter the execution side through
this architectural wrapper. A full finite namespace backpressures new keys.
Only quiescent ledgers can advance together using the controller's truthful
certificates. The controller advances first and emits its registered pulse;
the guard consumes that pulse on the next edge. Admission is blocked during
this explicit one-cycle generation synchronization bubble. Neither advance nor
STORE-only recovery resets cache/READ/WB state. New allocation and a stale packet
on the same edge match against the pre-edge ledger, so the packet cannot complete
the new allocation. Full numeric wrap still requires truthful old-copy quiescence.

The guard can accept later transaction results while an earlier architectural
result is held. It does not create a fence or guarantee cross-location retirement
order. The raw atomic controller serializes execution but retirement arbitration
is a separate bounded mechanism. P36 must specify memory-order/fence semantics;
they are not implied by P35 completion.

## Measured development proof (not canonical)

External task root: `/mnt/d/tmp/a0-p35-20260927`.
Each listed work directory is under `qualification-work/`, uses three variants,
exact Verilator 5.050, and passed diagnostics 0/0 and suppression leaks 0/0.
Each independent domain recorded outer/inner calls 4/16, with three elaborations.

| Suite | Work suffix | Scenarios per variant | Assertion checks |
|---|---|---:|---|
| Controller component | `component_development_7q78ikds` | 13 | 1101 / 1394 / 1542 |
| Requester guard | `retire_development_nb8t6014` | 6 | 227 / 311 / 479 |
| Raw cache-backed production | `integrated_development_jvinc6qz` | 10 | 6793 / 9001 / 11415 |
| Architectural production | `retiring_development_f3wdw74n` | 12 | 8651 / 11131 / 13935 |

All full work names have the prefix `a0_p30_p35_` before the table suffix.
The architectural production suite measured 33 transport request acceptances,
28 unique allocations/retirements and five exact duplicate/replay packets per
variant. It explicitly retries both the successful and failed competing CAS
without reevaluating the outcome, checks STORE-only failure/recovery with a held
atomic result, and verifies complete dirty writeback bytes through real P34.
The component suite additionally checks all descriptor fingerprint fields,
invalid opcode/odd 64-bit address while full, retained READ failure, TAKE miss
retry, and failed-CAS clean-byte/dirty preservation. Component clean-line fixture
setup is not a production-cache reset or a production integration claim.

Independent development raw audit:
`p35_development_raw_audit_wed0gzmz/raw-audit-receipt.json`, SHA256
`cda08b8b0eba2b1577e8b7925e8dfdde06949dc56f77cae186649609920c1c63`.
It checks all 40 raw command records, exact argv/cwd/timeouts, process lifecycle,
hash bindings, scenario order/counts, physical tool identities, strict logs,
full frozen source/raw-index and bounded live containment. Its in-memory parser
self-test accepted 12 real logs and rejected 96 deliberately corrupted copies.
Those synthetic copies are audit-tool tests, not additional RTL executions.

The earlier real dedup-removal fixture failed the non-idempotent ADD replay
witness as intended. Its original over-specific POSIX return-code audit failed
and remains historical; separate read-only evidence recovery validates the actual
WSL rc=1 plus exact assertion. A fresh canonical mutation run is still required.

## Required proof before canonical qualification

Three parameter variants, strict exact Verilator 5.050, zero diagnostics and
outer/real-inner suppression leaks. Component models are DEVELOPMENT only.
Production tests must instantiate the new wrapper with real frozen P34 RTL.
Directed proof includes 32/64 operation boundaries; cold fill/latest TAKE;
two-source same-address order; CAS winner/loser; replay before and after commit;
lost-response ADD retry; all descriptor-key mismatches; result backpressure;
full table with replay progress; generation advance/wrap/stale rejection;
normal STORE ordering; READ/WB identity; full dirty WB bytes; and inherited
STORE-only recovery preserving atomics. A separate mutation fixture disabling
committed dedup must fail a non-idempotent ADD replay witness.

Canonical and predecessor qualification, immutable raw evidence, source/index/
frozen containment, and verified ZIP packaging are distinct future steps.
Only live `.git/refs/codex/turn-diffs/` descendants may be excluded from live
comparison. Namespace root and every other Git/source path remain strict.
No commit, push, clean/reset, frozen rewrite, or GitHub reconstruction.
