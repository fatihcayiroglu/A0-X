# P184: bounded nextpnr heap placement search on real 64×64 ECP5

The previous P181 physical64×64 attempt on `dd7bd6ae97e8f261fce883aeb78820ae5c04a92f` synthesized successfully but **failed actual nextpnr placement**: `Unable to find legal placement for cell core.framebuffer.banks.storage.valid0_TRELLIS_FF_Q_1559_DI_LUT4_Z after 10001 attempts`. Raw run: https://github.com/fatihcayiroglu/A0-X/actions/runs/40316028984/artifacts/12648715510 . This is not an Fmax or proof of fit. Netlist showed 77 IO, 13 BRAM, 72 DSP, 9195 FF, 42839 TRELLIS_COMB placed estimate; 51% global LUT occupancy is not a guarantee of legal local placement.

## Controlled experiment

On current P180 corrected candidate `93b050f778312cdb9c6509de75519de507e423d2` (which has passed 17/17 exact-head jobs), keep **real Yosys synthesis, all 77 IO, same ECP5 85K/CABGA756/speed-6/seed-1, same 5 MHz *routability* floor and all logical/area assertions**. The first P184 run incorrectly passed `--placer-heap-cell-placement-timeout 100000`: nextpnr interprets this integer as a **divisor N**, not an absolute number of attempts. The budget is `max(10000, cells²/N)`, so the observed limit remained **10,000** and physical placement failed after 10,001 attempts for `valid0_TRELLIS_FF_Q_1511_DI_LUT4_Z`. Preserve the failed run and artifact as evidence. The corrected one-variable retry uses `--placer-heap-cell-placement-timeout 1` to increase the bounded search budget without turning off the placement guard. The run still has the original 60-minute job timeout, FPGA, seed, physical assertions and 5 MHz research floor.

This creates no synthesizable RTL changes. P183's optional 32×32 small-bank specialization, if later accepted, does not affect 64×64 where BANK_DEPTH=2048 and original dynamic validity branch is elaborated. No attempt to hide the initial failed placement or raise the workflow timeout.

## Acceptance

- The exact-head 64×64 job must complete successful *physical place and route* with actual `route.json` Fmax, 77 IO, actual RAM/DSP, LUT4/FF and real nextpnr logs/artifacts, not merely succeed in synthesis.
- If the larger search still cannot place, record the failure and test a separately scoped architecture/seed/placer hypothesis later. Do not report a successful 64×64 physical GPU.
- Preserve all previous correctness, P172 36.5 MHz timing, and P179 32×64 regression gates. Do not merge this proof until it succeeds and is integrated with full exact-head CI into the candidate/main process.

No claim is made about monitor outputs, PC graphics hardware, GPU game performance or RTX 6090-class operation.
