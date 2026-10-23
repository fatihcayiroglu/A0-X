# P46 — bidirectional *experimental* byte-to-graphics vertical slice

**Development status: software reference tested; RTL behavior NOT established until the strict gate executes.**

## Components

1. `a0_host_result_tx_p46.sv`: serialized 16-byte P44 result transmitter, one accepted P43 completion at a time. `result_valid && result_ready` atomically captures tag, error, and cycles. `out_valid && out_ready` consumes exactly one byte. Result inputs may change after acceptance without changing the held output. Reset cancels partial output. No flushing/replay/retransmission guarantee exists.
2. `a0_host_graphics_bridge_p46.sv`: P45 byte receiver -> existing P43 graphics/P42 two-bank frame buffer -> P46 byte result transmitter; common synchronous reset. The P43 completion `ready` directly reflects TX available-to-capture status.
3. Independent software TX reference, Python regression, HDL unit TB and integrated TB.

## Exact wire protocol

The P46 result is the existing **P44 format**:

- Bytes `0..3`: `A0GR`.
- Byte 4: protocol version 1.
- Byte 5: `0` (OK) or `1` (COMMAND_ERROR).
- Bytes `6..7`: P43 tag, little-endian.
- Bytes `8..11`: measured **local bridge clock cycles**, unsigned little-endian, saturated at `0xffffffff`. This is **NOT the Python P44 reference's cycle count** and is not a calibrated real GPU frequency.
- Bytes `12..15`: reflected IEEE CRC32/zlib of bytes `0..11`, little-endian.

P46 does **not** generate TIMEOUT (`status=2`). If downstream render never completes, there is no device timeout/fail-closed reset policy. The host must treat lack of progress as a timeout and reset/rebuild the complete transport. CRC is corruption detection, not message authentication.

## Crucial limitations

- Simulated host byte wires, **no PCIe/MMIO/DMA, GPU driver, physical VRAM, FPGA, ASIC, clock or power measurement**.
- Still uses independent P42 frame RAM rather than coherently accessing the P37 memory fabric.
- At most one frontend render command outstanding. A second may wait for P46's 16-byte output to drain. TX has no FIFO or flow-control timeout; if `tx_ready` stays low, progress can cease.
- `rst_n` resets RX/frontend/display/TX simultaneously. Reset can interrupt an accepted command or a partially emitted reply and **does not guarantee exactly-once behavior**. Tags alone cannot recover lost completions.
- Noncanonical or CRC-invalid P44 command frames are silently discarded and counted (when frame window magic aligns), with no result: an untrusted malformed frame cannot be acknowledged by tag.
- RTL gates are **strict**: tool absence returns 2; incomplete builds/runs return 1; only executed unit+integration simulation PASS returns 0.

## Verification instructions

```sh
cd A0-GPU
python -m unittest discover -s tests -p 'test_*py' -v
python tests/run_p45_host_rx.py
python tests/run_p46_host_bridge.py
```

Software unit tests confirm 500 randomized P44 result wire vectors plus directed backpressure/edge behavior against the preexisting protocol model. This **does not prove that the new SystemVerilog compiles, synthesizes, or functions**. Those claims await real simulator execution and independent HDL regression.

P37 remains NOT CLOSED. P45 RTL remains NOT RUN unless its separate strict runner has executed. The P46 bridge is NOT tied to the frozen P36/P37 source lineage and must not modify it.
