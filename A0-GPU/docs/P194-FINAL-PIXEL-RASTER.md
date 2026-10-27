# P194: real last-pixel raster and tiled Q8.8 boundary oracle

## Reason
P192 #69 proved full 256×256 frame clear sequencing and high-corner host reads, and the first tiny high-high triangle at (129,129). It did not actually shade and depth-write the **last global framebuffer pixel (255,255)**. P193 #70 independently attempts the full physical 256×256 ECP5 route and frequency gate; that long-running first result must be preserved unchanged.

## New actual Icarus test
The full P175 host, P38 raster, P162 programmable shader, P144 depth/RGB RMW, P139 XY routing and P138 48-bit bank memory are instantiated at 256×256 with `TILED_SCREEN_UV=1`.

1. Complete the ordered 65,536-address clear and verify global pixel readback and illegal host-read rejection as in P192.
2. Draw and check the original high-high triangle around (128,128), plus low-address nonaliasing.
3. **Without clearing**, reprogram vertices to (252,252), (262,252), (252,262) and issue a second real draw. The triangle extends beyond both frame edges and must clip, yet cover global framebuffer (254,255) and (255,255). Test the actual shader-output RGB `007e00` and `007f00` respectively, and written depth `000040`, reflecting local Q8.8 integer coordinates 126 and 127, not aliased low-address framebuffer indices.
4. Ensure the earlier triangle at (129,129) and the low pixel (1,1) are unchanged; validate shader retirement, reset-denied read, and the second complete reinitialization.

A failure is a real red result, not a retry/skip/waiver. Preserve simulator logs. This draft adds only test, CI, and contract documentation; it does not modify live RTL, relax resource bounds, or imply a physical GPU/card/driver.

## Integration
Stacked on P193 #70 pending exact-head physical route and independent review; P191 #68 and P192 #69 are also unmerged drafts. The next route/timing decision is governed by P193's original result, not by this test branch.
