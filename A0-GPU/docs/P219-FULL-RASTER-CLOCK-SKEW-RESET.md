# P219 — Full-raster clock skew and live stopped-clock reset (experimental)

**Stack:** draft P219 on draft [P218 #95](https://github.com/fatihcayiroglu/A0-X/pull/95). No RTL or real-board pin assignment changes.

## Positive proof

The complete P216 physical-EBR raster and committed host write path run under three separately clocked Icarus schedules (clock periods in simulation nanoseconds):

| Mode | Host | Pixel | Initial pixel offset |
| --- | ---: | ---: | ---: |
| 0 | 8 ns | 14 ns | 1 ns |
| 1 | 14 ns | 8 ns | 2 ns |
| 2 | 10 ns | 12 ns | 3 ns |

Each mode runs with **8 and 1,024 words**. Every run must commit two complete epochs through actual RTL storage, scan two entire frames without tearing, verify pixel-enable period, HSync/VSync/blanking, duplicate drop, front lock, rejected partial publication, post-fault reset, both physical pixel-EBR scrub banks and a 2 ns raw reset pulse.

At 8 words, each mode additionally stages a fresh live frame, waits for a **nonzero visible pixel**, halts **both independent clocks**, asserts raw reset for **2 ns without any clock edges**, requires immediate pixel blacking and reset assertion, resumes **pixel clock alone** and requires reset to stay asserted, resumes host clock, waits for qualification and both physical EBR scrub walks, and forbids stale front/pixel reappearance.

## Synthesis contract and scope

P219 inherits P218's six-crossing scoped inventory, nine CDC mutation rejections, P217 adversarial tests, older positive/negative gates, and an unchanged P216 **actual Yosys ECP5-85K CABGA381 + nextpnr route** with 83 top-level bits, at least 21 DP16KD, and two separate routed clock Fmax values of at least 10 MHz. Artifacts include per-mode positive logs and routed timing JSON.

**Not** a physical-board test, PLL/HDMI/DisplayPort test, formal metastability/MTBF analysis, guaranteed PVT/recovery-removal timing closure, product GPU, or driver compatibility proof. No actual board oscillator/pin constraints are supplied. Clock ratios are functional simulation schedules, not guaranteed clock constraints in hardware. CI must fail at the first actual bad assertion; no retries/skips. Draft PRs require owner approval and independent review before any merge.
