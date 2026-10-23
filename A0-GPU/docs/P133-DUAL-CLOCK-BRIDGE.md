# P133 — dual-clock bounded GPU command bridge

Status: **draft RTL candidate, based on P132 merged into main.** The dedicated real Icarus two-clock integration test passed on clean PR #8's initial head (`83b0d587`). Expanded black-box FIFO stress and actual P133 ECP5 synthesis gates are required on the latest PR head before reviewing for merge. This is not physical CDC or board qualification.

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

1. Real two-frequency Icarus test of ordered back-to-back writes, multiple outstanding queued commands, response backpressure, clear/readback, and reset draining/release. **Initial clean-head test passed.**
2. Add independent bidirectional FIFO stress tests with 41-bit and 33-bit data, deterministic varied stalls, capacity bounds, wraparound (512 transfers per direction), full/empty and in-flight shared reset; each received word checked against an independently calculated index pattern. **Added to CI; latest head results pending.**
3. Synthesize the full P133 + P132 + P102 path for ECP5 using genuine Yosys; fail on unmapped cells/latches and on missing distinct top-level host/GPU clocks. **Added to CI; latest head results pending.** This is *not* an automated CDC sign-off: pointer synchronizer placement/physical skew checks still require specialist tools and constraints.
4. After synthesis, implement a real FPGA placement-and-routing flow with explicit independent-clock constraints and Gray-bus physical skew limits; this would validate mapping and internal timing *only*, not an assembled board.
5. Preserve P126/P127/P132 green gates on the **exact P133 head**, finish manual CDC/reset architecture review, and only merge checks that actually passed. P132's own routed proof is not P133 routing proof.

## Excluded

Not PCIe, not USB, not an AXI peripheral, not physical FPGA board qualification. No bitstream, pinout, voltage bank, external I/O timing, clock constraints for a specific PCB, display output, VRAM, or measured performance.
