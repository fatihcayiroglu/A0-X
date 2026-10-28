# P206: actual on-chip FPGA block RAM behind P205 / P203

## Scope

P206 stacks on the verified P205 (draft #82). It instantiates the **complete
synthesizable** P205 narrow register mailbox, including its actual P203 tagged
transaction / write COMMIT acknowledgment bridge. A bounded in-hardware
controller consumes P205's controller-side 8-bit register protocol and
operates real synthesizable single-port **48-bit ECP5 embedded block RAM
(EBR)**, not the P196 simulation-only memory model.

The new host-facing P206 module exposes **29 I/O bits**: clock and reset (2);
the byte-addressed host bus (25); fault and busy (2). The controller-side
P205 bus is fully implemented *internally*, never tied off. The external
host register map remains exactly P205's register map.

Default FPGA memory geometry: **1,024 × 48 bits = 49,152 bits**, one small
on-chip bank. A testbench uses 8 words to prove wrap and reset boundaries.
Not two 256×256 frame banks and **not external VRAM**.

## Actual transaction and reset contract

1. Synchronous reset starts a full sequential zero scrub of every
   on-chip memory word. The internal controller **withholds P203's flush
   acknowledgment until scrub completes**, so the host cannot legally
   issue a command against stale contents.
2. Each controller command is fetched by byte from P205: operation,
   32-bit address, full 48-bit pixel, and 32-bit transaction tag.
3. A write takes effect at the block-memory clock edge. Only **after**
   that edge may the in-hardware controller assemble and submit the
   matching tagged COMMIT response; P203 holds the host write pending
   until it validates that response.
4. A read captures a synchronous block-memory value and returns all six
   bytes under the identical tag. Out-of-range requests produce error
   replies; the original P203 bank range check separately fails closed
   before issuing an out-of-bank transaction.
5. Unknown/unmapped controller states and unexpected P203 faults fail
   closed. Each reset scrubs RAM again; bytes are not left readable after
   a reset has completed. No asynchronous memory reads or multi-clock
   CDC are claimed.

## Required independent evidence

- Real Icarus RTL simulation with **no P196 memory model** connected:
  write/read two distant words, verify committed 48-bit values, reset
  all words to zero, reject incomplete writes and out-of-bank reads.
- Real Yosys `synth_ecp5` using P203, P205 and P206 and
  `check -assert`. Require mapped nonzero `DP16KD` EBR cells,
  `LUT4` and `TRELLIS_FF`, exactly 29 external I/O bits, zero
  unmapped modules/blackboxes/latches.
- Real nextpnr ECP5-85K CABGA381 speed6 place-and-route, unchanged
  mapped top; require Fmax ≥10 MHz, preserve first-failure artifacts,
  no unchanged-head retries, no skipped or fake-green gates.

## Nonclaims and next limits

P206 is a small **single-clock on-chip RAM** demonstration with a
byte-wide synthetic host register bus. It is **not** an FPGA dev-board
integration, production host link/PCIe, RAM PHY/DDR controller, independent
clock-domain boundary, GPU VRAM, a full compositor, graphics card,
game-driver stack, FPS result or a competitor to RTX 6090 hardware.
No real package pins/board LPF or off-chip timing constraints are selected.
The 10 MHz threshold is an honest experimental floor, not product
performance. Production external memory coherency and throughput remain
major separate milestones.
