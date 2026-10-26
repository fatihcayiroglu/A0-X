# P182: isolated constant-index framebuffer validity decoder experiment

Physical evidence motivates this change: P175 reference 16×16 route achieved 39.63 MHz; P180 corrected wide-UV route achieved 35.79 MHz (below the existing 36.5 MHz gate); narrowed-UV experiment achieved 34.10 MHz. The critical path ends at `storage.valid0/valid1`. The first 64×64 P181 place-and-route failed finding a legal placement for `storage.valid0` near 51% TRELLIS_COMB and 10% TRELLIS_FF use. The failures and raw artifacts remain authoritative.

## Hypothesis and isolated RTL change

The existing `valid0[bank0_write_addr] <= 1` dynamic-index assignment after reset may produce expensive variable write enables and broad routing. This experiment generates a constant-index equality decoder and dedicated enable for each validity bit in each bank. It changes **only** the implementation of validity metadata writes, not pixel data memories, bank arbitration, read-response protocol, or read-before-write behavior. Reset still synchronously clears all validity bits without resetting pixel BRAM data.

## Hard verification before adoption

- Real existing P126/P132/P139/P144 and P172/P173/P178/P180 frame+fault RTL tests, with no skipped or weakened assertions.
- Actual same-seed ECP5 16×16 placement must meet the original P175 **>=36.5 MHz** gate. Measure actual FF, BRAM, DSP, LUT4, TRELLIS_COMB, and route timing; no assertion of improvement before CI evidence.
- Record 32×32 and 32×64 FPGA placement/fmax when available and compare to baseline. Running test suites or simulation alone does not prove physical placement.
- Preserve failures and route evidence; if decoder increases congestion or breaks functionality, do **not** merge it. This draft stacks on P180 #57 until real exact-head evidence permits an integration choice.

A place-and-route clock is not GPU frame rate, display throughput, PCIe capability, production GPU hardware or an RTX 6090-class result.
