# P216 — separately clocked reset release through real pixel EBR pipeline

**Draft stacked on P215 (#92).** The output is an experimental ECP5-targeted RTL demonstrator, not a proven board design.

## Risk
P215 guarded short external reset pulses using a combined host-and-pixel-qualified `fabric_rst_n`, but that AND-combined signal could deassert on a remote clock edge. For asynchronous-reset registers in the *other* domain, its release timing was not locally controlled. P216 replaces the shared deassert signal in the active datapath with **separate host and pixel resets**, each deasserted by a flip-flop clocked in its own domain.

## Mechanism
- A raw low reset pulse asynchronously clears host and pixel readiness, synchronizer pipelines and local reset-up state, even if neither clock sees that pulse.
- Two local rising edges precede readiness assertion. Sticky remote readiness then crosses into each destination through **two synchronizer stages**.
- `host_rst_n` can rise only following a host rising edge; `pixel_rst_n` can rise only following a pixel rising edge. If either clock remains stopped, neither domain may restart.
- The legacy P214/P215 datapath is **left untouched**. P216 uses separate versioned modules for the P212 asynchronous Gray FIFO, P212 frame-queue, and P213/214 scrubbed two-bank raster. The P210 source resets from `host_rst_n`; FIFO write/read logic resets from host/pixel respectively; pixel epoch/fault/raster/scrub logic resets from `pixel_rst_n`.
- The diagnostic combined `fabric_rst_n` is **never wired to any sequential downstream block**. The 83-bit external top-level I/O remains unchanged.
- FIFO reset release can be skewed by a few cycles because each clock has its own frequency. The FIFO's existing two-clock post-reset startup gates and Gray-pointer synchronizers remain active.

## Required honest gates
- Icarus Verilog test with both 8ns/14ns and 14ns/8ns host/pixel clock orderings; six 2ns pulses per ordering. Assert that every local reset deassertion is timestamped on its own clock edge and occurs after two edges on both clocks. Stop pixel clock and verify the host cannot release alone.
- Full 8/1024-word physical EBR pipeline simulation. Two atomic VBlank frames, complete epoch checks, front lock, exact H/V sync, 2ns post-use reset, full zero scrub of both pixel bank arrays and no stale video.
- Preserve P175–P215 ancestor CI evidence, no skipped tests/retries/fake green. Actual Yosys ECP5 mapping plus nextpnr ECP5-85K CABGA381 routing with 83 I/O, ≥21 DP16KD, routed host/pixel clocks ≥10MHz minimum experimental floor. Artifacts preserved on failure.

## Not claimed
This is neither formal clock-domain crossing/MTBF proof, guaranteed asynchronous reset recovery/removal under silicon PVT, board/PLL/reset-device signoff, HDMI/DP interface, full PCIe/DDR graphics architecture, performance parity with Nvidia/AMD, nor a Windows/Linux/macOS production driver.
