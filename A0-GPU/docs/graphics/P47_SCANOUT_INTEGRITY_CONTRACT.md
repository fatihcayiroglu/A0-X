# P47 — Passive synchronous scanout frame-integrity diagnostics

**Implementation status:** software-reference verified, RTL simulation **NOT RUN**, not CLOSED.

## Scope

- `a0_scanout_frame_guard_p47.sv` observes an existing P42 ready/valid pixel stream.
- `a0_host_graphics_crc_bridge_p47.sv` wraps the unmodified P46 bridge and attaches the monitor.
- Diagnostic ports are local RTL signals. They do **not** implement host transport, a readback command, PCIe MMIO or a graphics driver.
- This is not pixel clock, HDMI, DisplayPort, video timing, DDR/HBM, FPGA or ASIC hardware qualification.

## Handshakes and input interpretation

All inputs are synchronous to `clk` with active-low synchronous reset `rst_n`. One pixel is accepted only if:

```
stream_active && pixel_valid && pixel_ready
```

Valid-but-stalled pixels cause no CRC or index progress. The caller must hold the beat stable under backpressure; this monitor does not enforce the producer's stability, although the RTL integration TB checks it separately.

On each accepted pixel, coordinates must follow row-major order, starting at `(0, 0)` after reset, disabling `stream_active`, or the previous completed/invalid frame. Expected marker rules:

- `start_of_frame` exactly on the first accepted pixel.
- `end_of_line` exactly when `x == FRAME_WIDTH - 1`.
- `end_of_frame` exactly on the `FRAME_WIDTH*FRAME_HEIGHT`-th accepted pixel.

Any coordinate/marker deviation is sticky through that frame. Early EOF terminates immediately with `frame_error=1`; a missing EOF on the expected last pixel terminates with `frame_error=1`. On EOF/expected final pixel, `frame_valid` pulses high for one clock after the accepting edge. `frame_error` and `frame_crc32` are stable until the next completion/reset; only interpret them when `frame_valid=1`.

If `stream_active` goes low while a frame is in progress, the partial frame is **aborted**, counter increments (saturating), accumulator cleared, and **no completed-frame pulse is issued**. If no frame is in progress, disabling the stream has no effect on counters.

All diagnostics counters saturate at `0xFFFFFFFF` rather than wrapping. Reset clears counters and in-flight state; reset does not prove or clear framebuffer physical RAM.

## CRC32 contract

The CRC is **CRC32/IEEE** (zlib compatible), reflected polynomial `0xEDB88320`, seed `0xFFFFFFFF` and final inversion. Each pixel's 24-bit `0xRRGGBB` is processed as **three bytes**: `BB`, then `GG`, then `RR`. No coordinate, flags, padding, transport framing or CRC fields are included. This CRC detects stream-byte errors probabilistically, not with cryptographic guarantees. Coordinate and marker invariants are checked separately.

Golden examples:

- 8x8 frame filled with `0x102030` => CRC32 `0xCC1199E5`.
- 2x2 frame `[0x112233, 0x445566, 0x778899, 0xABCDEF]` => `0x5CFCCABE`.

These fixed vectors are generated independently by Python's `zlib.crc32` and checked in both Python and RTL TB source. The second vector's TB will need execution under an HDL simulator to become RTL evidence.

## Validation separation

### Demonstrated in present environment

Run from `A0-GPU/`:

```
python -m unittest discover -s tests -p 'test_*.py' -v
```

This checks P47's Python reference, randomized backpressure cases, P42 synchronous scanout integration under the software model and inherited Python tests.

### Mandatory but **not executed** in this environment

```
python tests/run_p45_host_rx.py
python tests/run_p46_host_bridge.py
python tests/run_p47_frame_integrity.py
```

P47 testbenches:

- `tests/rtl/a0_scanout_frame_guard_p47_tb.sv` — fixed CRC vectors, stall, wrong coordinate, early EOF, interruption and reset.
- `tests/rtl/a0_host_graphics_crc_bridge_p47_tb.sv` — P44 CLEAR/PRESENT host packet, inherited P45/P43/P42/P46 RTL chain, scanout with stall, expected 8x8 image CRC.

These files are a runnable verification plan, **not** evidence of HDL PASS without actual compilation and execution. Gate returns **2** if Verilator/Icarus is absent. It returns **1** for failing compilation or simulation and **0** for executed passing tests.

## Remaining work

1. Re-run P45/P46/P47 TBs on a pinned Verilator/Icarus toolchain, inspect failures and fix real defects.
2. Differential RTL-vs-Python randomized framebuffer tests, including reset mid-frame, repeated frames, and a swap during scanning.
3. Expose validated frame diagnostics through a carefully versioned real host control/status interface if required.
4. Integrate real framebuffer backing/memory bus and command queue; present RTL wrapper is separate from P37 production memory architecture.
5. Requalify P37 closure independently. None of the above marks P37 or P47 CLOSED.
