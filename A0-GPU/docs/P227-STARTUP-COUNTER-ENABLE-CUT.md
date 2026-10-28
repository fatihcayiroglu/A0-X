# P227 — Remove redundant startup timing-counter enables

Status: **draft experiment**, based on exact-head green P226 `29e00bb`. Do not merge without owner approval, independent review, and P227's exact-head CI.

## Motivation and safety invariant

P226's same-seed ECP5-85K CABGA381 physical route used 13,323 LUT4 / 4,729 FF / 21 EBR / 83 I/O, and routed pixel 93.7734 MHz, host 53.8300 MHz. Its measured pixel critical path begins at `pipe_packet_q[66]`, flows through staged-frame/fault/publication selection and ends at the enable of `h_q`. It has 2.8 ns logic and 7.9 ns routing.

Before `run_q` first becomes one, `h_q`, `v_q` and `div_q` are zero because pixel reset asynchronously clears them and the `!run_q` branch does not otherwise advance them. The prior startup-publication block redundantly reassigns all three to zero on the same edge that asserts `run_q`, adding combinational ingress/stage controls to timing-counter write enables. P227 removes exactly these three redundant assignments. It **does not** remove reset, change in-run counter behavior, publication priority, fault/epoch validation, bank protection or CDC.

## Required validation

1. New P227 real EBR 8/1024-word × 3 clock-ratio journeys, exact 2 displayed epochs, VBlank swap, stopped-clock restart, short reset, no torn frames and retained nonzero stale-invalid lane guard.
2. New invariant: whenever domain reset released and `run_q=0`, all three counters must equal zero; fail if not exercised in each of six modes.
3. Preserve inherited P175–P226 positive and negative tests, including P222 mutants and P223 FIFO.
4. Independently route P216, P223, P224, P226 **and** P227 under the same ECP5 seed1/85K/CABGA381/speed6 contract. Preserve 83 I/O, at least 21 EBR and ≥4,700 FF, no unmapped cells/latches.
5. Strict prospective P227 performance acceptance: **measured pixel Fmax ≥ 1.03 × P226 Fmax** and **LUT4 ≤ P226 LUT4**, with host Fmax ≥90% of P226. If it fails, keep red and record measurements; no gate weakening, retries or fake green.

This is a synthesis/place-and-route datapath experiment. No board signoff, video PHY validation, CDC MTBF proof or real GPU performance claims.
