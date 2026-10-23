# P128 — real iCE40HX8K-CT256 mapping and P&R (not board proof)

P127 proved 4 selected RTL modules can be mapped to generic logic. P128 deliberately advances **only these modules** through technology-specific Yosys `synth_ice40` and actual nextpnr-ice40 place-and-route on `iCE40HX8K-CT256`.

* Fixed random seed 1 and internally constrained clock target **5 MHz**, report every mapped fabric resource and post-route Fmax. No `--timing-allow-fail` is used.
* Four test cases: combinational P68 depth comparator (routing and utilization only, **no clock Fmax**), P117 telemetry FIFO depth 4, P118 loss FIFO depths 4 and 7.
* This uses `--pcf-allow-unconstrained` because there is **no board or pin assignment**. This does not prove I/O timing, electrical feasibility on a real PCB, external SRAM/PCIe, DRAM, real graphics display, full GPU system integration, or measured clock speed.
* A pass means target primitives mapped, nextpnr produced a completed `.asc` layout in the sandbox, usable structured utilization, and clocked designs have an achieved internal Fmax at least 5 MHz. There is no physical programming; `.asc` outputs are discarded after verification and are not claimed as deployable hardware images.
* Failure and missing tool are separated with `FAIL` and `NOT_RUN`, exit codes 1 and 2. Evidence stored in GitHub Actions artifact, not committed.

Run on Ubuntu 24.04 with `sudo apt-get install -y yosys nextpnr-ice40 fpga-icestorm`, then `python3 -B A0-GPU/tools/a0_p128_ice40_pnr.py --evidence EVIDENCE/P128/ice40`.