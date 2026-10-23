# P133 — dual-clock bounded GPU command bridge (stacked draft)

Status: **RTL candidate — NOT VERIFIED until dedicated real two-clock test passes.** Base is P132's `p132/bounded-command-bus-contract` branch, not `main`. Rebase/retarget only after P132 is merged.

## Purpose

P132's request/response bus is synchronous to the GPU clock. A future host/board interface typically has a different clock. P133 introduces two small, finite queues that cross between one host clock and one GPU clock. It is a **CDC design candidate**, not proof of a complete physical GPU or PCIe device.

## Protocol

Host side:
- Inputs `host_clk`, `rst_n`, `h_req_valid`, `h_req_write`, `h_req_addr[7:0]`, `h_req_wdata[31:0]`, `h_rsp_ready`.
- Outputs `h_req_ready`, `h_rsp_valid`, `h_rsp_rdata[31:0]`, `h_rsp_error`.
- Request transfers on the host clock at `h_req_valid && h_req_ready`; no more than FIFO capacity requests can be queued before GPU consumption.
- Response transfers on the host clock at `h_rsp_valid && h_rsp_ready`. Keep payload stable while stalled. Requests and responses preserve FIFO order.
- The GPU side is connected to the unchanged P132 single-clock valid/ready adapter.
- Request FIFO payload is 41 bits (1 write + 8 address + 32 data). Response FIFO payload is 33 bits (1 error + 32 data). Each queue has depth 4 by default.

## CDC and reset rules

- Each FIFO stores a binary read/write pointer and sends a **Gray-coded pointer through two synchronization registers** into the opposite clock domain.
- Full and empty detection use only synchronized pointers. Do not directly use unsynchronized opposite-domain pointer or bus.
- Memory access only on ownership side; no overwrite when full and no consumption when empty.
- One shared active-low global reset is asserted to both clock domains. Deassertion is locally released through two clocked stages in each clock domain.
- Simultaneous reset discards all in-flight/queued transactions. Independent per-domain resets and arbitrary hardware power sequencing are **not supported**; such features require a separate epoch/flush protocol.
- Dual-clock RAM inference, metastability mean-time-between-failure, glitch-free physical reset tree and timing constraints remain **unqualified** until FPGA/board implementation.

## Required qualification gates before merging

1. Real two-frequency Icarus test of ordered back-to-back writes, multiple outstanding queued commands, response backpressure, clear/triangle/readback, FIFO full/empty, and reset draining/release.
2. Compare each bus response with independent expected values, reject missing, duplicated, or reordered responses.
3. Add strict CDC structure and synthesis lint; reject latch cells, unsynchronized pointer use, and any combinational host-to-GPU request bypass.
4. Synthesize full P133 bridge + P132/P102 under a device target and route with explicit timing constraints; this is *internal timing only*, never proof of external board signaling.
5. Preserve P126/P127/P132 green gates and only merge verified results.

## Excluded

Not PCIe, not USB, not an AXI peripheral, not physical FPGA board qualification. No bitstream, pinout, voltage bank, external I/O timing, clock constraints for a specific PCB, display output, VRAM, or measured performance.
