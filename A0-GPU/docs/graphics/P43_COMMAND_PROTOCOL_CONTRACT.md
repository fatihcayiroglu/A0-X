# P43 — single-outstanding command frontend (experimental)

**Project goal (2026-10-18):** software-based GPU architecture/RTL engineering,
verification and functional emulation only. No physical chip fabrication is in scope.
The project is NOT a manufactured GPU or an NVIDIA performance competitor yet.

## Command interface

`a0_graphics_command_frontend_p43.sv` is clocked by `clk`, active-low sync
reset `rst_n`. The source presents `cmd_valid` and must hold payload until
`cmd_ready && cmd_valid`. The frontend accepts at most one command at a time;
`cmd_ready` stays low until its completion result is accepted.

| opcode | mnemonic | payload | effect |
|---|---|---|---|
| `00` | `CLEAR` | 24-bit color | clear current render/back framebuffer |
| `01` | `TRIANGLE` | six signed 16-bit screen coordinates, RGB888 | draw triangle into render/back framebuffer |
| `10` | `PRESENT` | no meaningful arguments | request bank switch; completion is after swap DONE, not request acceptance |
| `11` | `INVALID` | ignored | return an error without side effects |

The host-assigned `cmd_tag` (default 16 bits) is returned as `completion_tag`.
`completion_valid` and `completion_error` remain stable when the host deasserts
`completion_ready`. The command is considered retired only when both completion
handshake signals are true. No new command can be accepted until retirement.
A reset cancels the command and any unconsumed response. A reset of the frontend
**alone** while a lower-level operation is in flight is unsupported; assert
`rst_n` on frontend and display wrapper together.

The frontend returns `completion_error=1` for invalid opcode, or for TRIANGLE or
PRESENT when `render_initialized=0` at initial command acceptance. `CLEAR` is the
required bootstrap after reset and after swapping to an uninitialized back bank.
Other error conditions (time-outs, DMA faults, device loss) are not modeled.

## State machine

`IDLE` -> `OFFER` -> `WAIT_DONE` -> `RESPONSE` -> `IDLE`, with early error
from `IDLE` -> `RESPONSE`. During OFFER exactly one lower-level valid is raised
and held until ready; during WAIT_DONE the matching done signal is required.
An unrelated done pulse cannot satisfy the command. Vertices, color, opcode and
tag are latched at initial acceptance, never read again from live input ports.

## P42 integration

`a0_command_triangle_sync_display_p43.sv` instantiates the P43 frontend and the
P42 synchronous two-bank pipeline. Front is scanned while only the back is
modified. PRESENT obeys the P42 EOF boundary when scanout runs, and commits
immediately if scanning is disabled. P43 is an experimental command entry point,
not a bus-connected production command processor. Missing features include:
command queues, addresses, DMA, PCIe, IRQ/MSI, firmware, shader execution,
host graphics API, depth, texture, and VRAM/production memory interconnect.

## Verification truth

- `python -m unittest discover -s tests -p 'test_*py' -v` runs reference tests.
- `python tests/run_p43_command.py --python-only` runs only 15 P43 Python tests.
- `python tests/run_p43_command.py` MUST execute HDL for a genuine P43 behavior PASS.
- When the complete HDL toolchain is missing, the strict runner exits **2**;
  parse/elaboration/lint cannot close P43 or prove equivalence.
- `python tests/p43_render_demo.py --output /tmp/demo.png` creates reference-
  software image, not a GPU RTL or hardware output.

Unresolved design-risk cases include frame-swap/reset timing under synchronous
RTL, cross-geometry parameter regressions, command liveness under scanout
permanent backpressure, and later compatibility with the P37 memory fabric.
