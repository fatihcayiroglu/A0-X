# P205: narrow, fail-closed 8-bit mailbox around the real P203 bridge

## Hardware objective

P204 physically routed **the unmodified P203 tagged controller** at 337
parallel top-level I/O bits, 105.13 MHz reported post-route for an ECP5-85K
CABGA756. That interface is too pin-heavy for a practical board.

P205 preserves that *same* P203 RTL inside a new synthesizable top exposing
only **54 total I/O bits**:

- Common clock/reset: 2 bits.
- Host-side synchronous register bus: 25 bits (valid, write, 6-bit
  address, 8-bit write data, ready, 8-bit read data).
- Controller-side synchronous register bus: 25 bits (same arrangement).
- Direct diagnostic `fault` and `busy` bits: 2 bits.

No P203 data, tag, or control signals are tied off to shrink the pin
count. All 32-bit physical word addresses, 48-bit pixel words and 32-bit
transaction IDs are actually serialized **as byte-indexed register accesses**
via two independent single-clock mailboxes.

### Host register map

| Address | Access | Meaning |
| --- | --- | --- |
| `0x00` | W | `1` submit prepared command, `2` acknowledge completed result |
| `0x01` | R | status: bit 0 flush required, 1 command pending, 2 read wait, 3 done, 4 fault, 5 bridge busy |
| `0x02` | W/R | command: `0` read, `1` write |
| `0x04..07` | W/R | 32-bit physical word address, little endian |
| `0x08..0D` | W/R | 48-bit RGB+depth word, little endian |
| `0x10..15` | R | 48-bit read response data, little endian |
| `0x16` | R | response error bit |

A submit requires a valid operation byte, all four address bytes, and
all six data bytes for writes. Data is stable until actual P203
acceptance/COMMIT. A write only reports DONE after a successful matching
**write COMMIT acknowledgement** from the external controller, not on
request enqueue. A read only reports DONE after its validated response.
A completed response must be acknowledged before preparing the next
command. Partial, overlapping or illegal writes fail closed.

### Controller register map

| Address | Access | Meaning |
| --- | --- | --- |
| `0x00` | W | `1` acknowledge reset/flush, `2` submit response |
| `0x01` | R | bit 0 flush requested, 1 request pending, 2 response pending, 3 fault |
| `0x02` | R | requested operation |
| `0x04..07` | R | requested physical address |
| `0x08..0D` | R | requested 48-bit data |
| `0x10..13` | R | requested 32-bit transaction ID |
| `0x14` | W | response error: 0 or 1 |
| `0x18..1B` | W | response transaction ID |
| `0x20..25` | W | response data bytes for reads |

The wrapper forwards P203's flush barrier and tagged request/response
protocol. It will never publish the host's result simply because the
controller fetched a request. The controller must explicitly report
successful completion for the **same ID**; P203 rejects mismatches,
missing replies and reset-stale messages. Both buses are single-clock;
cross-domain synchronization is **not** provided and must be engineered
before connection to a differently clocked host.

## Test and FPGA contract

1. Run the full inherited real P175 double-frame P203 chain at the P205
   exact head (131,072 data commits; 200 old-bank reads) and P203
   standalone negative tests.
2. New RTL test uses both narrow register buses and the real P203 bridge.
   A write is committed to the actual **P196 simulation-only** memory
   model before the fake controller posts the matching COMMIT response.
   Read data must return through the byte registers unchanged. Negative
   probes reject partial commands, stale/mismatched IDs, wrong physical
   bank, duplicate KICK and incomplete controller replies.
3. Require `synth_ecp5`, `check -assert`, real
   `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --seed 1` placement
   and route, exactly 54 mapped physical top I/O bits, nonzero LUT4 and
   FF, no blackboxes/latches, and actual post-route Fmax of at least
   **10 MHz**. Preserve real reports and failures; no waiver or retries.

## Boundaries

This is a *slow, synchronous register mailbox proof*, not a production
USB/PCIe link, AXI, I2C controller, dual-clock CDC, memory PHY, DDR
controller, or complete GPU on FPGA. The CABGA381 package has no actual
board pinout or external timing constraints here. Physical PnR is
computer-aided FPGA fabric fitting, **not silicon hardware measurement**.
The P196 memory array remains simulation-only. No real VRAM, display
driver, PC game compatibility or performance claims follow from this work.

## Merge gate

P205 remains a stacked **draft** on P204 (#81) and ancestors. Require
exact-head clean CI and independent review; no merge without approval.
