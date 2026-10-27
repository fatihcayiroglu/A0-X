# P197 — Synthesizable external word command arbitration (experimental)

## What is hardware and what is a model
- New \`rtl/memory/a0_p197_external_word_port_arbiter.sv\` is **synthesizable** Verilog/SystemVerilog combinational/sequential control logic.
- It joins the actual P195 two-word FIFO write output with one host read-request port and drives a single generic external-memory command channel: \`mem_cmd_valid/ready/write/word_addr/pixel\`.
- Accepted writes complete **at the command handshake**, not at a physical DRAM commit. Reads admit one outstanding command, and their single unbackpressured response is returned through registered \`read_rsp_valid/error/pixel\`.
- P196's 65,536-word memory is **simulation-only** test infrastructure. The new arbiter does not synthesize a memory array, train DRAM, implement a memory PHY, PCIe/AXI, DMA, cache coherence, a display scanout, nor connect to the live P175 rasterizer.

## Fail-closed protocol contract
- Addresses are 32-bit **word** addresses over the inclusive window \`BASE_WORD_ADDR..BASE_WORD_ADDR+FRAME_WORDS-1\`. Reads outside the window get one registered local error; invalid writes are consumed with one \`write_fault\` pulse and never sent to memory. P195 producer coordinate rejection remains upstream.
- The memory end must accept commands on \`mem_cmd_valid && mem_cmd_ready\`, deliver *exactly one* \`mem_rsp_valid\` for every accepted read, and never send a response for a write. An unsolicited response latches \`protocol_fault\` and blocks all commands until common reset.
- A memory response has no \`ready\`. The caller must consume \`read_rsp_valid\` pulses.
- Both the adapter and memory response producer **must share reset/flush semantics**. Reset cancels pending read ownership; a delayed stale response after reset is not safe for a new epoch unless the memory end flushes it.
- External command data and address are held stable through \`mem_cmd_ready=0\` if each upstream producer obeys the standard valid-holds-until-ready protocol. Round-robin grant changes only on accepted commands.

## Exact-head acceptance
Dedicated GitHub Actions job:
1. Real Icarus compilation/simulation wires P195 FIFO → new P197 synthesizable arbiter → P196 simulation-only word memory.
2. Checks all 1,028 frame writes in exact order, 200 concurrently requested corner reads under deterministic bus stalls, both fairness winners, held external command stability, invalid local/bus read responses, out-of-range local write refusal, common reset retention and pending discard, unsolicited response fail-closed and reinitialization.
3. Real Yosys \`synth\` and \`check -assert\` on the **P197 RTL controller only**. CI uploads evidence on success or failure and uses bounded timeouts without retries/skips.

## Still blocked for genuine graphics hardware
- Integrate a stable read/write bridge with P175 only after separate review and resource/timing validation.
- Replace P196 simulation backend with a real, documented FPGA memory interface/controller and run real nextpnr routing and board tests. No claim of VRAM, board throughput, game performance, or competitive GPU performance.
- Keep this stacked PR draft pending independent review and exact-head CI. No main-branch merge implied.
