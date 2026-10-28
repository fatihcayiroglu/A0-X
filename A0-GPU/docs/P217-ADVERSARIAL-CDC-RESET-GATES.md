# P217 — adversarial cross-clock reset release and mutation guard

**Stacked draft on P216 (#93).** The core RTL remains byte-for-byte identical to the previously passing P216 physical 21-EBR pipeline. This phase strengthens evidence rather than claiming new hardware functionality.

## Structural risk
A green boot test is insufficient if a future edit bypasses one of the two flip-flop synchronizer stages, lets a host reset release before the pixel clock is alive, or accidentally swaps FIFO domain resets.

## Fail-closed gates
1. A new Icarus clock-skew adversarial test runs with 8ns/14ns and 14ns/8ns clock periods. It injects **12 raw 2ns pulses in each ordering**, observes per-clock release timestamps, checks each reset waits for at least 2 edges in both domains, and verifies **three destination edges** after remote-ready (two FF synchronization stages plus local release FF).
2. It explicitly stops the pixel clock and separately stops the host clock after raw reset. Neither reset may release until both clocks recover.
3. The Python mutation gate requires the actual P216 source's two-flop synchronizer structure and per-domain reset wiring. It generates **six compiling but intentionally broken supervisor variants** (one synchronizer stage bypassed, output-stage bypassed, or remote-ready check omitted), and demands a real simulation `FATAL:` for every variant. A seventh negative case swaps FIFO reset wiring and must be rejected by the topology check.
4. P175–P216 inherited functional gates continue to run. The exact P216 top is physically re-synthesized with Yosys ECP5 and placed/routed on ECP5-85K CABGA381 with 83 I/O, ≥21 DP16KD, and separate physically reported host and pixel Fmax each ≥10 MHz. Artifact logs are retained even if a step fails. **No retries, skips or silent bypasses.**

## Honest limits
Dynamic tests plus source-mutation checks are **not formal CDC signoff**, a complete crossing inventory, silicon metastability MTBF, asynchronous reset minimum pulse width guarantee, recovery/removal/PVT signoff, or board pin/oscillator constraint validation. `nextpnr --freq 10` is only an experimental generic routing constraint; absent a real board assignment no LPF pin map or production signoff is claimed.

The P216 datapath and all earlier candidate PRs remain unmodified, draft and subject to independent review / owner merge approval.
