# P207: two independent reset-scrubbed on-chip EBR banks

P206 (draft PR #83) provides one real synthesizable ECP5 embedded RAM bank
behind the complete P205/P203 byte-mailbox/tagged-commit chain.

P207 instantiates **two separate complete P206/P205/P203 hardware paths**
with adjacent physical word address windows:

- bank 0: `BASE_WORD_ADDR .. BASE_WORD_ADDR + WORDS - 1`
- bank 1: `BASE_WORD_ADDR + WORDS .. BASE_WORD_ADDR + 2*WORDS - 1`

At the default `WORDS=1024` each bank holds **1024 × 48 bits**. Both banks
are independently implemented, reset-scrubbed and backed by inferred ECP5
`DP16KD` cells. The combined host interface still exposes just **29 bits**
(25-bit byte register bus, clock/reset, fault/busy).

## Bank selector (shared host register)

`0x30` is a new top-level register, intercepted before either P206 host:

- Read: bit0 currently selected bank, bit1 an incomplete/staged command,
  bit2 bank0 busy, bit3 bank1 busy, bit4 any sticky fault.
- Write `0` or `1`: select bank0 or bank1. Allowed **only** after both
  banks are idle, no host command is staged/in flight, and no fault exists.
- Selector writes during staged data, pending completion, or an active RAM
  operation, and invalid values, set a **sticky fail-closed fault**. No
  selected-bank change occurs. Reset is required to clear a fault.

A staged operation starts as soon as the host writes any operation/address/
pixel byte, and remains staged through COMMIT and the host's DONE ACK.
The selector cannot migrate a half-written command, an in-flight tagged
write, or an unread result to a different bank.

**Reset scrubs both memories independently** before allowing transactions.
Each P203 still checks its own physical address range and matching
transaction tag. The controller returns write COMMIT only after its actual
BRAM write clock edge.

## CI contracts

- Run inherited full P175 two 256×256-frame P203 proof, P203 error tests,
  P205 narrow byte tests and P206 on-chip memory acceptance.
- New Icarus test **without a simulation memory model** at `WORDS=8` and
  default `WORDS=1024`: write two edge addresses of each bank with distinct
  48-bit values, switch and verify isolation, scrub and verify zeros after
  reset, reject staged/active/invalid bank selectors.
- Require real Yosys `synth_ecp5`, `check -assert` and actual
  `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --freq 10` route.
  Top pins exactly 29, **at least six real DP16KD** cells for 98,304 data
  bits, nonzero LUT4/FF, no blackboxes, physical Fmax ≥10 MHz, first
  failure preserved without skipped or retried gates.

## Boundaries

This is **two small on-chip SRAM-like banks**, not a completed double-
buffered scanout: selector is host-command bank selection only, *not*
atomic frame publication or video display. No external DDR/VRAM, PCIe,
CDC, board pin assignment/LPF, PHY, power characterization, silicon test,
application driver or RTX 6090/FPS claim. Measured Fmax is experimental
post-route ECP5 only; it is not a card clock specification.
