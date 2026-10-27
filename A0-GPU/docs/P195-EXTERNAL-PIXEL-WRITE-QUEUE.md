# P195: bounded external pixel write stream, not a memory controller

## Motivation and scope
P193 proved the 256×256 research renderer can place/route on ECP5 85K,
but its 48-bit on-chip framebuffer already consumes 193 of 208 BRAM blocks.
Future resolutions require an external-memory architecture. This milestone
provides one *separate, unconnected* 2-word ready/valid pixel write queue
to test the data-loss and backpressure contract first.

This does **not** provide DDR/VRAM, physical pins, an AXI/PCIe endpoint, read
path, coherence, arbitration between read/write clients, bank/row scheduling,
error correction, memory-ordering fences, or durable write acknowledgements.
The 32-bit output address identifies a 48-bit **pixel word**, not a byte.
The downstream `out_ready` signals bus acceptance only; it is not evidence
of memory completion.

## RTL contract
- Parameterized frame geometry up to 65,536 total pixels, in-bounds
  (x,y) linearized to `BASE_WORD_ADDR + y*FRAME_WIDTH + x`.
- 2-entry FIFO; when full, valid writes wait until space is available.
- When the downstream side accepts a word on the same cycle, the producer
  may push another even if previously full. Output order remains FIFO.
- An out-of-bounds coordinate is acknowledged and emitted as a one-cycle
  `reject_valid` pulse; it consumes no FIFO slot, even while full.
- Reset discards only *queued, unaccepted* words, asserts no outputs, and
  forgets old rejects. A future system must explicitly define reset
  semantics for in-flight accepted downstream writes.
- Overflowing the 32-bit address range is a parameter-elaboration error.

## Actual gates
The P195 Icarus test uses an acceptance-time expected FIFO, compares
each drained `{address,pixel}` once and in order, and fails immediately
on duplicated or unexpected outputs. It exercises simultaneous full
pop+push, five-plus producer stalls, invalid x/y while full,
1,024 address/data payloads under deterministic repeated downstream
stalls, complete drain, and reset discard/restart. Test reports 1,027
accepted and drained valid words, plus two rejected writes before reset.

The workflow must run actual Icarus simulation and Yosys synthesis;
no skips, retries, marker-only substitution, or assertions removed to
force a green result. Preserve logs on failure as evidence.

## Integration and next steps
This PR is stacked as a **draft** on P194 #71; it intentionally does
not change or connect the P175 framebuffer. Integration depends on
independent review and exact-head CI of P190–P194. Before a larger
frame is advertised, implement the real upstream pixel read/write
arbiter and downstream external memory model/controller, pressure-test
read-modify-write depth semantics, and validate on an FPGA board.
