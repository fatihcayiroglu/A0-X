# P228 — Last-word commit enable independent of 32-bit rollback comparison

**Draft experiment stacked on exact-head-green P226 #103, NOT on failed P227 #104.**
The target is an ECP5-85K LFE5U CABGA381 speed-6, seed-1 route, not a GPU
die, physical board, video connector, game workload, or MTBF validation.

## Physical hypothesis

P227's recorded failed same-seed 95.5749 MHz pixel route moved its
critical path to `stage_epoch_q[31]` through the 32-bit older-epoch check,
fault and skip-ingest control to `stage_epoch_q[18].CE`. P226
(13,323 LUT4, pixel 93.7734 MHz) remains the comparison foundation.

`first_ingest` is true only at `ingest_index_q==0`; `last_ingest`
is true only at `ingest_index_q==WORDS-1`. The supported WORDS
is 4–1024, a power of two, hence these cannot both be true.
The old capture clock-enable `consume && last_ingest && !bad_sample
&& !skip_ingest` unnecessarily depends on 32-bit epoch rollback
comparators, which are **only relevant to the first word**.

P228 adds `last_sample_commit`, directly preserving each relevant
last-word condition: `consume` (valid, scrub, fault); expected final
index; exact start/end markers; nonzero epoch matching the frame's
first-word `ingest_epoch_q`; nonduplicate `ingest_skip_q`.
The stage epoch data itself is loaded from the validated first-word
latch. The full `bad_sample` comparisons remain unchanged for
**every bank write**, including first-word older-than-front/stage rejection;
the full `bad_sample` still raises permanent pixel fault on invalid
frame data. Startup, VBlank priority and scrub logic stay unchanged.

## Test and honest acceptance

- Six *actual* real-EBR 8/1024-pixel, 3-clock-ratio end-to-end videos,
  each with complete source epochs, VBlank isolation, duplicate drops,
  2ns reset, stopped clocks, and nonzero held-invalid payload proof.
- On every sampled pixel cycle after scrub, check `last_sample_commit`
  **equals the original full fail-closed predicate**. Also check stage
  epoch register equals the first-word epoch after each accepted
  end-word posedge. Mandatory nonzero counts, ≥2 captures/mode.
- Preserve all inherited P175–P226 positive and negative steps; no
  test skipping, retries or relaxing a failing gate.
- Independently synth/place/route both full P226 and P228 on same
  speed, package and seed; demand 83 pins, ≥21 EBR, ≥4700 FF,
  no unmapped cells/latches and independent host/pixel clocks.
- Prospective physical Pareto gate: **P228 LUT4 ≤ P226 LUT4**, pixel
  Fmax **≥1.03×** P226 Fmax, host Fmax **≥0.90×** P226 Fmax.
  If red, keep it red and record exact metrics.

**Not a board signoff, consumer video PHY, gaming benchmark or performance
claim against desktop GPUs.** Never merge without owner approval,
independent review, and exact-head green CI.
