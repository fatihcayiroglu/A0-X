# P131: device-specific full P102 graphics feasibility on ECP5-85K

**Target:** Lattice `LFE5U-85F`, speed grade 6, `CABGA756` package, an internal
1.0 MHz clock constraint. The large package is deliberate: the unwrapped P102
RTL exposes hundreds of parallel debug/coordinate/command bits and would exceed
the approximately 205-user-IO budget of the smaller CABGA381 package. This is
**not** a good real-world host interface and must be replaced in later stages
by a bounded, clock-domain-safe command/readback bus.

**What P131 is designed to prove:** On a real Linux CI runner, use Yosys
`synth_ecp5` on all five original integrated source modules, P102 set to a 4x4
framebuffer; require an actual device-specific mapped top and `check -assert`.
Then use `nextpnr-ecp5 --85k --package CABGA756 --speed 6` to place and route.
Only accept real post-route `utilization` and `fmax` in the JSON report if every
resource is within capacity, no timeout or tool failure occurred, and the
routed clock meets 1.0 MHz. The nextpnr ECP5 report names physical LUT BELs `TRELLIS_COMB` (not `TRELLIS_SLICE`). Never use `--timing-allow-fail`.

**What P131 does not prove:** No user-specified board, pin assignment/LPF,
external I/O timing, bitstream/flash operation, VRAM/PCIe/monitor connectivity,
physical device testing, full real-world GPU workload, nor hardware timing
measurement. The 1 MHz threshold is an engineering fit probe, **not a
performance target**. A fitted design is not a usable integrated graphics card.

**How to run:**

```bash
sudo apt-get install yosys nextpnr-ecp5
python3 -m unittest discover -s A0-GPU/tests -p 'test_p131_ecp5_fit.py' -v
python3 A0-GPU/tools/a0_p131_ecp5_fit.py --evidence EVIDENCE/P131/ecp5
```

For missing tools, the runner returns `NOT_RUN` and exit 2. For failed mapping,
over-capacity, route error, or timing failure, it returns `FAIL` and exit 1;
the JSON and logs are uploaded even on failure. Only genuine full-device
mapping, place-and-route and post-route timing can produce `PASS` and exit 0.