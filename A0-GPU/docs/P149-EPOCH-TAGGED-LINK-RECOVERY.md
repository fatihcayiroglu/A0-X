# P149 — Epoch-tagged host requests, watchdog and fail-closed soft recovery

**Status: DRAFT; no merge without latest-head real RTL and FPGA evidence.**

P149 wraps the unchanged P148 ordered four-slot FIFO, full signed-16-bit P147 packed command bus, P146 raster, P144 depth/alpha and P139/P138 genuine FPGA block RAM. The standalone P149 top does **not** claim PCIe, DMA, device interrupts, multiple clock domains, physical link training, or real hardware communication.

## Request and reply identity

The one-clock host transport adds an **8-bit `req_id`**, returned as `rsp_id`, plus a **16-bit `rsp_epoch`** and `link_reset`/`link_fault` handshake signals. The original 77 I/O bits from P148 become **111 exposed logical I/O bits**. Up to eight accepted transaction IDs are queued independently of P148's four request slots and held response; the whole package has enough headroom for four pending P148 requests, one currently issued transaction and one held response. Each accepted request inserts exactly one ID into the ring; its ID is popped **only when the matching response is acknowledged** on `rsp_valid && rsp_ready`. Errors, valid pixel reads and ordinary register replies retain input order.

The ID is an **opaque, possibly reusable token**. The tuple `(rsp_epoch,rsp_id)` distinguishes a software reset generation from the previous one only while the 16-bit epoch has not wrapped. Epoch rollover is **not** a global uniqueness guarantee; a real host must quiesce or handle wrap and reset deliberately.

## Reset and timeout semantics

- On power-on `rst_n=0`, ID FIFO, response, watchdog and generation all return to zero; the underlying P148/P147/BRAM are also reset.
- On synchronous `link_reset=1`, all accepted-but-incomplete work is **cancelled**, all P148/P147 state is reset, `rsp_valid` is suppressed and `req_ready=0`. A held-high link_reset increases epoch **once**, not each cycle. After it deasserts the new epoch can accept clean commands.
- A bounded `WATCHDOG_CYCLES` counter (default 512; allowed 2–65535) monitors **absence of the oldest backend response** while accepted work exists. A response held by the host with `rsp_ready=0` does not age out. If a backend response never appears by the deadline, `link_fault` latches; all outstanding work is cancelled/quarantined and requests/replies are blocked until explicit `link_reset`. Host observes failure via `link_fault`, not a fake normal response.
- The watchdog is a **research protocol hang detector**, not an established PCIe Completion Timeout or production-safe transaction replay. Cancelled commands might have had effects before the fault: higher software layers must read back state and reconcile before retrying. Never promise exactly-once side effects across reset.

## Required tests

1. Genuine Icarus full P149 input bus -> P148/P147/P145/P144/P139/P138 -> original P102 oracle on **4×4, 7×5, 8×8**, with **−257/+1024 full signed 16-bit coordinates**, alpha/depth/scissor, clear, reset, invalid command/XY and every color/depth pixel checked. Every matching reply ID and epoch is asserted; the graphics test must not bypass P149 transport.
2. Adapt actual P148 host-stress suite to P149: **365 accepted ordered mixed writes/reads/errors**, IDs checked individually, held response/4-queued backpressure, no losses/duplicates, 121 error replies, soft link_reset cancellation of one held response + four queued requests, held reset changes epoch exactly once, clean post-reset readback.
3. Separate **deliberate backend nonresponse fault injection** during a real registered read: trigger timeout with WATCHDOG_CYCLES=16, verify sticky fail-closed fault, no stale response after backend release, recovery only via `link_reset`, epoch increment, real device ID read, invalid-register error and clean register reset, then hardware reset to epoch 0. The test must explicitly disclose fault injection and not misrepresent it as naturally occurring.
4. Genuine Yosys `synth_ecp5` plus nextpnr ECP5-85K CABGA756 speed6 seed1, 4×4 internal framebuffer, `--freq 5 --lpf-allow-unconstrained`. Require **exactly 111 top-level I/O bits**, ≥2 actual DP16KD BRAM cells, no unmapped cells/latches, bounded fabric utilization and a complete clock timing report.
5. Inherited P126/P127/P132/P134/P148 regressions must pass on the **exact PR head**, not just on an earlier commit. A failed, skipped or pending required job means NO merge.

## Verified RTL and FPGA evidence — 24 October 2026

At code head `f5216d62`, all **five** triggered exact-head GitHub Actions workflows succeeded: P126, P127, P132, P134 and P149. The P149 job used the *actual* P148/P147/P146/P145/P144/P139/P138 pipeline with Icarus Verilog, not a mocked GPU.

**Transaction-ID stress:** 365 ordered mixed writes, reads and invalid requests returned 365 matching IDs with 121 correctly tagged error responses. An unacknowledged response remained stable while four more commands filled the queue and produced 12 demonstrable full-queue stalls. A held soft-reset cancelled one held response plus four pending requests, incremented `epoch` **exactly once** over four reset cycles, and subsequent fresh reads returned the expected register values with the new epoch.

**Watchdog failure-injection stress:** with WATCHDOG_CYCLES=16, the test explicitly forced the wrapper's *observed* backend-response-valid low while the true P147 engine was present. It confirmed latched `link_fault`, zero leaked stale responses, a deliberate link reset increasing epoch to 1, three subsequent real P147 replies (including one expected error), and physical-reset epoch returning to 0. This verifies the bounded fault-control behavior, *not* full hardware fault coverage or crash-safe software replay.

**Genuine end-to-end tagged command / P102 RGB-depth oracle:**

| Framebuffer | Clears | Completed draws | Pixel RGB/depth readback comparisons | Tagged bus transactions | Expected error transactions | Actual dual-pixel commits |
|---|---:|---:|---:|---:|---:|---:|
| 4×4 | 2 | 5 | 112 | 636 | 55 | 29 |
| 7×5 | 2 | 5 | 245 | 1,198 | 55 | 64 |
| 8×8 | 2 | 5 | 448 | 2,060 | 55 | 121 |

Each returned tag and epoch was checked at the actual host interface, while framebuffer color and depth matched the unchanged independent P102 reference, including signed 16-bit vertices outside the previous 8-bit wrapper.

Real Yosys ECP5 mapping and nextpnr ECP5-85K placement/routing with CABGA756 speed6 seed1, 4×4 framebuffer, 5 MHz internal research clock target and unconstrained external pins **passed**. The complete P149 top exposes **111 of 365 available FPGA I/O bits**, maps **4 genuine DP16KD** RAM primitives and reports **21.4147 MHz** estimated clock Fmax. For context P148's separately routed research top reported 22.16 MHz, so the extra control logic did not improve tool clock speed.

The final documentation commit requires its own exact-head CI rerun. No physical board clock, PCIe protocol, VRAM or gaming FPS evidence follows from these research results.

## Limits

Transaction IDs and epochs do not establish authenticated commands, software drivers, production PCIe, actual external VRAM, physical FPGA pin constraints, measured game FPS or a finished graphics card. Soft reset abort is not automatic application-level replay. Do not estimate GPU readiness from PR numbers alone.
