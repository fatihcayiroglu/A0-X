# P105 logical host–dual-bank–telemetry contract (development candidate)

## Connected RTL modules

P45 `a0_host_command_rx_p45` accepts 32-byte canonical P44 command packets
(`A0GC`, version 1, CRC32/IEEE). P104 operates two P102 fragment/back-bank
engines, P43 serializes commands, P42 reads the displayed front bank. P46
encodes 16-byte `A0GR` command result packets, P47 checks accepted scanout
pixels and produces CRC32/IEEE, P48 sends 32-byte `A0GF` frame telemetry, and
P49 packet-atomic arbiter multiplexes results and telemetry onto one logical
byte stream. All six earlier components and P104 remain byte-identical.

## Legacy P44 limits, deliberately exposed

P44 version 1 has no depth/scissor/blend fields. P105 configures `depth_op=ALWAYS`,
`depth_write=0`, `blend_enable=0`, and `scissor_enable=0`; the triangle's RGB
and vertices come from the packet. Depth and scissor support **cannot** be
controlled using this interface. CLEAR uses a depth value of 0xFFFFFF and
TRIANGLE uses the same unused depth value. No claim of programmable modern
fragment pipeline is made.

`PRESENT` retires when P104 flips bank ownership, not when every pixel was
accepted. A following CLEAR may draw in the opposite bank while scanout runs.
P104's `scan_active` drives P47's `stream_active`; do not use the external
`scan_enable` level for this monitor because it can be removed after PRESENT
acceptance without aborting the current scan.

Results and telemetry are **not** guaranteed to appear in the same order as
command/scan completion. The P49 mux arbitrates in complete packet units.
P48 has one queued telemetry frame; it cannot block scanout, so telemetry
can be dropped during sustained host TX backpressure. A0GF's sequence and
saturating dropped counter are diagnostic, not proof of delivery. CRC checks
transport/frame bytes, not the semantic correctness of shading.

## Negative and acceptance gates

- `python -m unittest discover -s tests -p 'test_*.py' -q` checks the software
  contracts only, including corrupted command/telemetry rejection.
- `python tests/run_p105_host_dual_bank.py` compiles an independent host-level
  SV bench with Icarus and runs it. Without `iverilog` and `vvp` the result
  is exit code **2 / NOT RUN** (not PASS). Compilation or simulation failures
  return exit **1 / FAIL**; testbench success returns exit **0 / PASS**.
- Manual workflow `.github/workflows/a0-p105-host-dual-bank-rtl.yml` requires
  an explicit run in a repo containing `A0-GPU` at the repository root.
- The bench asserts four canonical command results, two unbroken 4x4 frame
  scans, host CRC32 for every packet, pixel CRC32 for both frames, counter
  consistency, no extra unsolicited pixels/bytes, and holds/stalls.

## Out of scope

No physical PCIe, DMA, VRAM controller integration, host driver, shader
compiler, FPGA verification, frequency/timing closure or silicon validation.
P37–P104 legacy RTL qualification gaps are not retired by P105 Python tests.
