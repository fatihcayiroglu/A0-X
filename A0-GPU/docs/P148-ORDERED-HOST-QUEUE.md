# P148 — ordered host-command queue and lossless response backpressure

**Research scope: one clock domain, not PCIe, DMA or external VRAM. Status: unqualified until same-head RTL/FPGA CI green.**

## Why and what changed

P147's 32-bit packed register host interface handles one request at a time and emits a one-cycle `rsp_valid` pulse without host response acknowledgement. It is correct only when the host reliably consumes that pulse. Real host bridges must tolerate host slowdowns while commands are queued and results become available asynchronously.

P148 adds a separate `a0_p148_ordered_host_queue_top` wrapper **around the unchanged P147 full-16-bit-coordinate raster, P144 depth/alpha RMW and P139/P138 FPGA BRAM**. No P147 or active P102/P132/P133 modifications.

- A fixed **four-entry request FIFO** stores complete `{write,5-bit address,32-bit data}` packets (38 bits each), in acceptance order. A request is accepted on `req_valid && req_ready`. When full, `req_ready=0`; the host must hold/retry its request. A simultaneous push/pop adjusts occupancy without reordering. No silent drop/overwrite.
- At most **one downstream P147 request in flight** and **one host response awaiting acknowledgement**. The P148 back end issues the oldest queued request only when P147 is ready, no other operation is outstanding, and the prior response has been consumed. This serializes all register writes, CLEAR/DRAW acceptance, readbacks, rejects, and status polls without overtaking.
- A host response exposes `rsp_valid,rsp_error,rsp_rdata` until a **rising-edge** `rsp_valid && rsp_ready` acknowledgement. Error results are also ordered and must never block following valid requests once acknowledged.
- The host-side external interface adds only **one wire (`rsp_ready`)** to the P147 76-bit interface, for an expected **77 exposed I/O bits**. No clock crossing, physical pin assignment, PCIe transaction layer, AXI fabric, bus mastering or hardware driver is asserted.
- Shared active-low reset flushes host FIFO occupancy, pending downstream issue, any outstanding response and all P147/P145/P144 stored state. Reset *cancels* incomplete operations rather than replaying them; a real host would need a higher-layer reset/sequence/recovery protocol.

## Required test evidence

- Genuine Icarus P148 queued-bus vs unchanged P102 complete RGB888/depth24 frame differential on **4×4, 7×5, 8×8** with full signed-16-bit vertices **−257,+1024**, two clears, five completed draw commands, depth modes, alpha blend, scissor, invalid host commands/XY and mid-render reset. All P147 register accesses must work through the *new* queue. Preserve identical color/depth values, dual-bank write counts, and negative test handling.
- Separate real RTL FIFO stress test: stall response acknowledgement while another **four requests fully occupy the FIFO**, prove `req_ready` is low and `rsp_valid,error,data` remain stable; unblock, require ordered delivery including an invalid command. Exercise **365 total requests in a controlled burst (including the initial group)** and mixed readbacks/writes/errors with repeated deterministic host stalls, compare each response against an independent ordered expectation list. Reset during a held response with four pending requests; demand empty queue, no stale replies, correct P147 reset register values.
- Genuine Yosys `synth_ecp5` + nextpnr ECP5-85K CABGA756 speed6 seed1, 4×4 framebuffer, 5MHz research internal timing target, unconstrained package I/O. Require **77 top-level port bits**, ≥2 genuine `DP16KD` BRAM primitives, no unmapped logic or latches, bounded I/O utilization and actual timing report. Do not claim any clock beyond the routed estimate.
- Re-run inherited P126, P127, P132, P134 and active P147 P102/FPGA regression workflows on the **exact final PR head**. Never merge a failed/pending/missing regression.

## Actual real RTL + ECP5 verification — 24 October 2026

The code-head [GitHub Actions run 40101904318](https://github.com/fatihcayiroglu/A0-X/actions/runs/40101904318) completed both genuine jobs successfully.

**FIFO stress, real Icarus + complete P147/P146/P144/P139/P138 RTL:** 4 queue slots filled while an earlier response was held; **12 full-queue stall cycles** and **12 held-response-stability cycles** observed. Host then drained **365 ordered requests** (initial five plus 120 iterations × 3) including **121 correctly ordered error replies** without a missing or duplicate response. Reset with **one response held plus four requests queued** cancelled all 5 pending epoch transactions; the next reset epoch returned two valid fresh read responses, including an expected reset register value.

**Independent unchanged P102 reference (the entire real packed bus + full 16-bit raster + dual-bank BRAM):**

| Frame shape | Clears | Finished draws | Color/depth pixels compared | Host transactions | Invalid/rejected requests | Two-pixel commit cycles |
|---|---:|---:|---:|---:|---:|---:|
| 4×4 | 2 | 5 | 112 | 636 | 55 | 29 |
| 7×5 | 2 | 5 | 245 | 1,198 | 55 | 64 |
| 8×8 | 2 | 5 | 448 | 2,060 | 55 | 121 |

Signed vertex values **−257 and +1024**, alpha blending, LESS/LESS_EQUAL depth, scissor, degenerate triangles, bad commands, invalid pixel coordinates, reset during a triangle and registered readback were exercised. All frame RGB and stored depth matched P102; inherited P126/P127/P132/P134 work on the same head also passed before the document update.

**Genuine FPGA technology mapping:** Yosys plus nextpnr ECP5-85K, CABGA756 speed6 seed1, 4×4 internal frame, 5MHz research target, unconstrained external pins routed successfully. The actual top has **77 I/O bits** (77 of 365 available TRELLIS_IO), **4 mapped `DP16KD` block RAM**, no unmapped cells/latches and **22.162 MHz tool-reported single-clock Fmax**. P147 baseline is **21.367 MHz** using a different, unqueued top; this slight Fmax difference is not a measured throughput gain, since FIFO handshakes also increase command latency.

The final documentation-only PR head must rerun and pass its own CI before merge.

## Limits

P148 prioritizes strict ordering and **no lost response** over host-side maximum transaction rate. Only a **single downstream P147 request** is processed at once, and the response buffer holds one word. It is not a multi-engine scheduler, PCIe block, physical signal integrity test, hardware VRAM, GPU driver, display scanout or proof of any gaming frame rate. A follow-on P149 might add explicit command transaction IDs and error/retry/recovery semantics, but none is implied here.
