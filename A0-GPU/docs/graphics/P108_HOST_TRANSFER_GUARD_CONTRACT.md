# P108: no-blind-replay host transport guard

**Scope:** Software reference / offline fault injection; no real device API or RTL.

`TransferGuard(compiled_session, epoch=..., reset_acknowledged=True, max_chunk=..., timeout_ticks=...)` exposes `poll(logical_tick, writer_callback)`, `audit(capture_bytes)`, and `receipt()`. `verify_receipt(session, receipt_dict)` validates receipt internal consistency. `reset_acknowledged=True` is a statement from the caller; no physical reset is performed or observed.

## States

| State | Meaning | In-epoch retry permitted? |
|---|---|---|
| `SENDING` | Writer may accept remaining stream bytes; zero returns do not advance cursor | Yes, until bounded progress timeout |
| `HOST_ACCEPTED_UNVERIFIED` | All planned bytes accepted by the writer callback; hardware execution unknown | No |
| `ABORTED_NO_PROGRESS` | Writer reported zero accepted bytes until timeout | No; begin fresh reset epoch |
| `ABORTED_UNCERTAIN` | Partial then timeout, invalid writer result, or exception of unknown effect | **No**; begin fresh reset epoch |
| `CAPTURE_AUDITED_SOFTWARE_ONLY` | P107 strict audit accepted a supplied capture after all host writes accepted | No; capture provenance unverified |

A positive return `n` means *n bytes reported accepted by the host transport callback*, not decoded or executed by the GPU. If a callback raises (even at the first call), its side effects may be unknown: state becomes uncertain. Never replay a partial command without independently establishing a fresh device state.

### Exact boundaries and checks

- Packet length is discovered from compiled P107 wire protocol version: v1 32 bytes, v2 56 bytes. Each writer offer stops at the current packet boundary and at `max_chunk`.
- Track exact accepted prefix `wire[:offset]`, SHA-256 and successful host writer events; reject invalid counts, `bool`, nonmonotonic ticks and out-of-range values.
- `timeout_ticks` measures logical ticks since last positive writer progress. This is a *test model*. Real drivers require watchdogs and I/O cancellation; none are implemented.
- Once terminal, another `poll()` fails. A future real implementation must ensure an independent reset acknowledgment and establish a distinct epoch; this model cannot prove reset or secure epoch uniqueness across processes.
- A P107 capture can only be audited in `HOST_ACCEPTED_UNVERIFIED` state, and an audit failure never yields false completion.
- `verify_receipt()` replays accepted-length offsets and checks SHA-256 prefix digests and packet boundaries. Receipt is unsigned; anyone able to alter the document can synthesize another internally consistent receipt.

**Exit-code behavior of offline CLI**: `simulate` returns 0 only for full scripted host acceptance, and (when optional capture provided) successful strict P107 capture audit. Return 1 otherwise. `verify` returns 0 only for *internal consistency*, never physical provenance.

**Required future qualification:** live transport adapter, robust device-side reset/epoch ID, atomic command transaction semantics or safe recovery after unknown completion, authenticated receipt/capture provenance if needed, deterministic RTL tests in Icarus/Verilator, FPGA host integration, full product driver/security/performance evaluation.
