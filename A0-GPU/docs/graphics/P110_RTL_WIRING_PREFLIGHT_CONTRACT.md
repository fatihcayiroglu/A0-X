# P110 — bounded RTL wiring preflight (development, not qualification)

## Why

P43 → P102 → P104 → P106 host/graphics integration spans a 14-file SystemVerilog
compile set. Prior software tests are Python behavior models, **not** a compile
or simulation of this RTL. P110 adds a deterministic source-structure check
that can run without a simulator and fail a build before HDL qualification.

## Exact scope

`python3 A0-GPU/tools/a0_p110_rtl_wiring_preflight.py` reads the 14 sources
listed in `SOURCES`, parses ANSI module port names, and checks the *bounded*
known P106 RTL hierarchy: 13 source-level instantiations, 243 explicitly
named port connections. It checks source presence and port lists, missed,
duplicate and unknown pin names, empty/positional/wildcard connections, and
specified dependency-edge multiplicities. The two P102 banks are created by a
single generate-loop source-level instantiation, counted once here.

Output JSON records SHA-256 hashes of the 14 exact source files and explicitly
sets `rtl_compiled`, `rtl_simulated`, and `physical_gpu_proven` to false.
Negative mutation tests in `tests/test_p110_rtl_wiring_preflight.py` check that
missing/incorrect wiring and missing dependency edges fail closed.

## Non-claims and limitations

This is **not a SystemVerilog parser/elaborator**. It does not verify parameter
expansion, bit widths, port directions, expression semantics, timing, reset,
handshake correctness, synthesizability, waveform results, bus interoperability,
performance, FPGA configuration or silicon behavior. It does not detect new
unknown module types inserted into the hierarchy, nor all possible syntax
errors, malformed nested comments or macros. The contract is restricted to
this fixed compile set and the explicitly listed named dependencies.

## Required next gate

When a Linux runner with `iverilog` and `vvp` is available, launch the manual
`.github/workflows/a0-p110-rtl-qualification.yml` workflow from the repository
root. It must compile and run real P103, P104, P105 and P106 RTL testbenches;
any non-zero exit fails CI. If not run, the RTL qualification is **NOT RUN**.
P37's independent canonical qualification and any P45–P102 inherited missing
HDL gates are still separate open evidence requirements.

No project maturity percentage increase is justified by these source checks.
