# P133 — dual-clock bounded GPU command bridge

Status: **verified RTL/research FPGA-mapping candidate**, based on merged P132. PR #8 exact head `2da9bc9a` passed real Icarus two-clock integration, both 512-transfer FIFO stress tests, full Yosys ECP5 synthesis and nextpnr ECP5-85K route at an artificial 1 MHz constraint. Inherited P126/P127/P132 workflows passed on that same commit. This is **not** physical CDC, external pin, board, PCIe, thermal or product qualification.

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

## Verified research gates on PR #8

1. **PASS:** Real two-frequency Icarus integration tests: back-to-back commands, ordered responses, errors, clear/readback, reset draining/release, and 24 distinct write/read pairs after deliberately saturating both request and response FIFOs.
2. **PASS:** Independent 41-bit/33-bit FIFO stress tests with deterministic varied stalls, occupancy bounds, wraparound (512 transfers per direction), full/empty and in-flight shared reset; every received word checked against an independently calculated index pattern.
3. **PASS:** Genuine Yosys ECP5 synthesis of complete P133 + P132 + P102 path; 81 top-level I/O bits, 11,287 mapped cells, no latch/unmapped cells, two separate top-level clocks.
4. **PASS with strictly limited meaning:** Real nextpnr ECP5-85K placement and routing (`CABGA756`, speed 6, seed 1), internal 1 MHz timing met for both reported clocks. Reported unconstrained-board-clock maxima: GPU 9.77 MHz, host 84.85 MHz. These are **tool-reported mapping numbers**, not guaranteed device speeds; I/O timing is deliberately unconstrained and asynchronous CDC skew is not signed off.
5. **PASS:** P126 18 actual RTL regressions, P127 generic synthesis and P132 full differential RTL + ECP5 route workflows green on exact head `2da9bc9a`. This P133 route is separate from P132 routing evidence.

## Still required for physical CDC and board qualification

A constraint-reviewed multi-clock timing plan, Gray-bus max-skew/bus-skew constraints, synchronizer placement analysis, CDC/RDC tool review, reset release/power sequence validation, realistic independent host/GPU frequencies, real PCB pinout and electrical/timing measurements. Do not infer these from a 1 MHz unconstrained-pin route; this milestone only qualifies a mapped research candidate.

## Excluded

Not PCIe, not USB, not an AXI peripheral, not physical FPGA board qualification. No bitstream, pinout, voltage bank, external I/O timing, clock constraints for a specific PCB, display output, VRAM, or measured performance.
