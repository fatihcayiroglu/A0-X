# P196: persistent external-memory model readback (simulation only)

## Aim
P193's 256x256 on-chip framebuffer already occupies 193/208 ECP5
BRAM blocks. P195 adds a separate two-entry, ordered external pixel
write stream, but its success confirms only downstream handshakes.
P196 connects that **real P195 RTL** to a stateful external word-memory
**simulation model**, adds independently arbitrated host reads, and
checks the retained values. This is a proof of the bus contract and
data integrity under contention, not a DDR/VRAM controller.

## Model's deliberately constrained behavior
- 65,536 addresses of 48-bit packed RGB888/depth24 words, based at
  `0x0100_0000`. Addresses refer to pixel words, not bytes.
- One operation per cycle: read or write, never both. When both sides
  request service, priority alternates after each accepted access.
- External `allow_write/allow_read` signals impose deterministic stalls.
- Read responses are registered pulses on the following clock, with
  no downstream response backpressure, and error on unwritten or
  out-of-range addresses. Invalid writes report `write_fault`.
- Protocol reset clears response/priority state and P195 discards
  unaccepted queued writes. **Previously accepted memory data persists
  through reset**; model backing storage is never reset.
- This is not synthesizable DRAM or a verified external memory PHY.
  There is no bank/row timing, refresh, ECC, burst ordering, PCIe, AXI,
  DMA, cache coherency, fencing, or write-completion acknowledgement.

## Honest RTL acceptance
Actual Icarus instantiates the unchanged P195 queue plus the model:
1. Four widely separated 256x256 word writes, read back precisely,
   and reject unwritten and off-range reads.
2. Reject two invalid producer coordinates, with no memory allocation.
3. Drive 1,024 ordered writes concurrently with 200 known-data reads
   on the one-port model under deterministic write/read stalls.
   The scoreboard compares every acceptance and committed address/data,
   checks both arbitration sides were granted under real contention,
   and verifies a sample of newly written words.
4. Fill the FIFO while downstream is disabled and reset before those
   pending writes are accepted. Read persistent prior memory contents,
   show the discarded writes remain unwritten, then verify fresh
   post-reset writes/readback.

No skip/retry or forced green. Preserve failing simulator output.

## Integration boundary
P196 is a **draft stacked on #72**. It adds only testbench/model/CI
and documentation, leaving production P175 RTL and P193 FPGA routing
untouched. Before larger frames are advertised, separately build a
synthesizable external memory controller, bidirectional framebuffer
arbiter, real RMW transaction pipeline, hazard handling, and on-board
timing/functional validation. Exact-head CI and independent review
remain required.
