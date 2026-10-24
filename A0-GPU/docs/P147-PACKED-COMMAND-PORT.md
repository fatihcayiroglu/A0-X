# P147 — bounded 32-bit packed register/command interface

**Status: DRAFT. Do not merge without same-head real RTL + ECP5 route evidence.**

## Why

P145 and P146 can draw triangles from **full signed 16-bit coordinates** internally, but the earlier ECP5-85K CABGA756 research wrapper restricted its six external vertex coordinates to **signed 8 bits** just to fit the package: it exposed 318 of 365 usable I/O pads. The original full-width direct top could not be placed because it needed 366 I/Os. Neither design is an actual pin-assigned physical board.

P147 restores **all six signed 16-bit coordinate inputs** over a **32-bit, one-request/one-response register protocol**, with a 5-bit register address, request valid/write and ready, plus response valid/error and data. The independent physical top has **76 logical I/O bits** by RTL port counting (verify actual mapped pins in Yosys/nextpnr). One clock domain only. No PCIe, DMA, real bus IP, physical pinout, CDC or production protocol qualification.

Each accepted request has a registered response. A rejected command/address returns `rsp_error`. New requests are blocked while a response is outstanding. A **pixel-read command** waits until P144/P139/P138's actual registered BRAM readback is available before responding; its color/depth results are then cached in two readable registers, and invalid XY rejects and clears the previous result. Clear and triangle draw commands acknowledge acceptance *not completion*; callers must poll sticky `CLEAR_DONE`/`TRI_DONE` flags in STATUS. Core busy/fault/initialized and read/command-ready bits can also be polled.

## Register map (5-bit offsets; each transfer 32 bits)

| Address | Name | Write | Read |
|---|---|---|---|
| 0 | CLEAR_RGB | RGB888 in [23:0] | same |
| 1 | CLEAR_DEPTH | depth24 in [23:0] | same |
| 2 | TRI_RGB | RGB888 in [23:0] | same |
| 3 | TRI_DEPTH | depth24 in [23:0] | same |
| 4,5,6 | V0,V1,V2 | signed x[15:0], signed y[31:16] | exact signed pair |
| 7 | SCISSOR_XY | unsigned x[15:0],y[31:16] | same |
| 8 | SCISSOR_WH | unsigned width[15:0],height[31:16] | same |
| 9 | MODE | depth compare [1:0], depth write bit2, blend bit3, scissor bit4, alpha[15:8] | same |
| 10 | READ_XY | unsigned x[15:0],y[31:16] | same |
| 11 | COMMAND | 1=CLEAR,2=DRAW,3=READ_PIXEL; fail-closed for busy/unknown | **read rejected** |
| 12 | STATUS | **write rejected** | init bit0, busy1, fault2, clear-done3, tri-done4, pixel-valid5, clear-ready6, tri-ready7, read-ready8 |
| 13,14 | PIXEL_RGB / PIXEL_DEPTH | **write rejected** | 24-bit result when pixel-valid; else error |
| 15 | IDENT | **write rejected** | `0xA0147001` |

MODE reserved bits [31:16] and [7:5] must be zero or the entire write fails without altering the previous mode. Commands on an unready core fail rather than being silently dropped. Framebuffer clearing invalidates the last debug-read cache, and reset clears all config, in-flight responses, sticky completions and raster state.

## Strict acceptance gates

- Icarus actual bus + full raster/RMW/BRAM vs unchanged independent P102 original on **4×4, 7×5, 8×8** with two clears and five completed draws including depth comparisons, alpha blending, scissors, degenerate, reset-during-render and all **48-bit color/depth pixels** after each draw.
- Draw triangles with signed coordinates **−257 and +1024**, not representable by signed 8-bit ports. Verify exact register readback of all signed 16-bit fields before launch. No shortening these tests to pass.
- Check invalid command/addresses, attempts to overwrite read-only registers, MODE reserved bits, pixel-read after reset, rejected command while busy, invalid XY, and actual P144 registered debug response. Count actual dual-bank write completions (through test-only internal signals).
- Genuine Yosys `synth_ecp5` and nextpnr `--85k --package CABGA756 --speed 6 --seed 1 --freq 5 --lpf-allow-unconstrained`, mapped **real P147 + P146/P145 + P144/P139/P138** with 4×4 framebuffer. Require at least **2 real `DP16KD` blocks**, no unmapped logic/latches and **<=96 exposed logical I/Os** against CABGA756 365-IO limit, with full utilization/timing evidence.
- Preserve inherited P126/P127/P132/P134/P145/P146 workflows on the **exact final PR head**. Keep draft if any required test is missing/failed/pending.

## Nonclaims

This is an **FPGA research register protocol**, not a real PCIe endpoint, motherboard interface, physical card or VRAM memory controller. Command transfer overhead and polling exist; no gaming frame-rate, system-wide GPU performance or production board-level electrical/timing guarantees follow from these checks.
