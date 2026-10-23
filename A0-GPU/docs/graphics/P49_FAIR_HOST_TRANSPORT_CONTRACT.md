# P49 logical host TX fairness and capture audit (DEVELOPMENT)

## Observed P48 limitation

P48 `a0_host_tx_frame_arbiter_p48.sv` grants results on every simultaneous
IDLE request. A continuous result backlog can delay A0GF frame telemetry
indefinitely even if `host_ready` remains asserted. This is a liveness,
not merely a packet-CRC, limitation.

## P49 proposed change

`a0_host_tx_fair_arbiter_p49.sv` is an *additive, opt-in* 16/32-byte
**complete-frame** arbiter:

- After reset, both lanes requesting => A0GR result wins.
- After **completing** a result frame, the next simultaneous tie chooses A0GF.
- After **completing** telemetry, the next simultaneous tie chooses A0GR.
- An otherwise idle preferred lane does **not** block the live one.
- Arbitration occurs only between complete frames, never byte-by-byte.
- Accepted output bytes may pause arbitrarily under `host_ready=0`.
- A stalled selected producer must keep `valid`/byte stable until handshake.
- A granted producer that retracts valid mid-frame violates the source contract;
  the arbiter does not synthesize missing bytes or guess recovery.
- No wall-clock fairness is guaranteed if the host refuses bytes indefinitely.
- P48's 1-frame telemetry buffer may still drop events under congestion, but
  sustained accepted result traffic no longer causes unlimited arbitration
  starvation with another ready telemetry frame waiting.

New top `a0_host_graphics_fair_bridge_p49.sv` preserves the P47/P48 pipeline
and substitutes only the new arbitration. P48 source remains byte-identical.
This is a **logical stream model**, not a driver, PCIe endpoint, DMA, or PHY.

## Host audit tool

`tools/a0_host_trace_p49.py` reads a supplied binary capture. P46 result frames
are 16 bytes (`A0GR`), P48 telemetry frames 32 bytes (`A0GF`), both with CRC32.

Example:

```bash
python tools/a0_host_trace_p49.py --capture /path/to/capture.bin --report /path/to/report.json
```

The tool exits nonzero on detected invalid candidates, discarded bytes or an
incomplete tail unless `--allow-corruption` was explicitly requested.
`--require-lossless` also exits nonzero on observed telemetry gaps, repeated
sequence numbers, counter regressions or increases of the dropped-events count.

Important limits:

- A0GF sequence is 16-bit; after 65536 events it aliases. Reported modulo gaps
  are minimum detectable gaps, **not an absolute loss guarantee**.
- A telemetry counter is snapshotted when its packet is enqueued, and cannot
  describe drops which occur later without another packet being transmitted.
- Device resets, capture truncation and adversarial CRC collisions are not
  necessarily distinguishable from ordinary missing records.
- The parser cannot prove the capture came from physical GPU hardware.

## Required closure evidence

1. RTL simulation with a named Icarus/Verilator version: P45 through P49 suites.
2. New P49 RTL bench output and wrapper lint/compile, zero unexpected failures.
3. Independent pin-trace-vs-Python tests for both lanes, simultaneous requests,
   TX stalls, reset, sequence wrap, and a continuously loaded result lane.
4. Bounds and failure behavior if an upstream source violates `valid` stability.
5. Hardware transport demonstration before any physical-link claims.
6. P37 canonical qualification stays a separate, still-open dependency.

Do not mark P49 or P37 `CLOSED` based solely on software references.
