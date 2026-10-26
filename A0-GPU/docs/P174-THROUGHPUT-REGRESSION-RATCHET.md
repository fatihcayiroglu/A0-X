# P174 — CI throughput nonregression ratchet

## Exact measured baseline

P173 (PR #49, with independent P102 full-frame oracle) measured:
| Real RTL framebuffer | 5-instruction / 2-TEX program | 3-instruction / 1-TEX program |
|---|---:|---:|
| 4×4 (16 shaded fragments) | 834 clocks | 562 clocks |
| 8×8 (64 shaded fragments) | 3,330 clocks | 2,242 clocks |
| 16×16 (256 shaded fragments) | 13,314 clocks | 8,962 clocks |

The measurements follow `52*pixels + 2` and `35*pixels + 2`. These are
clock counts from the **accepted draw** to the real **core completion** pulse,
without host framebuffer readback; they include shader/raster/depth/BRAM work.

## Regression contract

The P173 CI job asserts for each of the three geometries:

- The complete P102 independent color/depth result and functional/fault checks
  still pass.
- The heavier shader has no more than `52*pixels+2` clocks.
- The lighter shader has no more than `35*pixels+2` clocks.
- Faster hardware passes the upper bounds; slowdowns fail CI and require an
  explicitly justified performance budget change and renewed exact-head
  functional and FPGA evidence.

This ratchet does not prove general-purpose GPU throughput. It only covers these
two shader programs and tiny 4×4/8×8/16×16 frames. Routed 16×16 37.17 MHz
is a separate physical-design measurement, not an achieved graphics FPS, and
neither metric can be used as an RTX performance comparison.
