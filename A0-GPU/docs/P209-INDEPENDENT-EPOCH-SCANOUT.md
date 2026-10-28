# P209: independent, epoch-tagged physical EBR scanout prototype

## Hardware scope

P208 provides two primary 1024×48-bit on-chip EBR banks with a fail-closed
publication fence and unique-address tagged-COMMIT coverage. P209 **does
not change** the P203/P205/P206/P207/P208 implementations. It wraps the
unchanged P208 producer with **two additional real ECP5 EBR shadow banks**,
one per corresponding primary bank. This deliberately duplicates the
pixel storage to allow a separate simultaneous read port without forcing
extra RAM read ports into the proven primary EBR timing/placement contract.

- Producer writes still go through the complete P208→P207→P206→P205→P203
  host-byte, tagged controller, real primary-RAM commit path.
- A P209 shadow word is written **only on a validated host WRITE DONE,
  error=0, and matching ACK**. The mirror write occurs at that ACK clock
  edge, *after* the P203 controller confirmed the actual primary write.
  Invalid or early ACK cannot create a published shadow frame: the
  unchanged P208 fails closed, and P209 independently rejects it.
- Both shadow banks are synchronously scrubbed word-by-word after reset,
  separate from the primary banks. No scanout request is accepted until
  both reset barriers have completed and a full P208 frame is published.
- A successful P208 publish is acknowledged by the scanout wrapper on
  the following clock after checking the P208 fault line; scanout
  requests are blocked during this handoff. A registered front-bank
  selector and 32-bit publication epoch determine the pixel returned.
  Each accepted read request captures its own epoch and bank.
- Writes to the published front remain rejected by P208. When the back
  is filled, P209 can read the immutable published shadow **in parallel**
  with primary-bank/byte-bus producer activity.

Default physical RAM footprint is two **primary** and two **shadow**
1024×48-bit banks, total **196,608 physical storage bits** (12 ECP5
DP16KD blocks expected, versus six at P208). The additional shadow
capacity is a deliberate temporary throughput tradeoff, not an external
VRAM memory controller.

## Physical top-level I/O

The original 29-bit producer host interface remains intact. Scanout
adds 93 bits, for a target of **122 total**:

| Interface | Direction | Bits |
| --- | --- | ---: |
| Producer clock, reset, 8-bit register bus, fault and busy | Mixed | 29 |
| `scan_req_valid` | Input | 1 |
| `scan_word_index` | Input | 10 |
| `scan_req_ready` | Output | 1 |
| `scan_rsp_valid` | Output | 1 |
| `scan_rsp_pixel` | Output | 48 |
| `scan_rsp_epoch` | Output | 32 |
| **Total** | | **122** |

All interfaces are **one clock domain**. The scanout port is a
one-cycle registered read without downstream output backpressure.
Consumer software/hardware must accept each valid reply on time.
Out-of-range scan indexes are not acknowledged for `WORDS<1024`.

## Acceptance and nonclaims

- Icarus test with **8 and 1024** words per bank, two complete committed
  frames, simultaneous front read requests while the second bank is
  written, valid 48-bit data and epoch 1/2, front write-lock,
  out-of-range scan refusal where representable, reset scrub of all
  primary/shadow RAMs. No simulation-only P196 memory is used by
  P209's new test.
- Re-run inherited P175 dual-frame 131,072-word, P203 negative
  controller tests, P205 mailbox, P206 actual EBR, P207 dual-bank and
  P208 full publication tests at both sizes.
- Actual Yosys `synth_ecp5` and ECP5-85K CABGA381 speed6
  `nextpnr-ecp5` route, **122 I/O**, **at least 12 DP16KD**, nonzero
  LUT4 and FF, no unbound modules/blackboxes or latches, real post-route
  Fmax >=10MHz. Preserve first-failure evidence, zero skips/retries.

**Not yet a complete display engine:** no actual pixel clock or
HDMI/DisplayPort timings, scanline schedule, frame-boundary swap
coordination, consumer buffering, independent CDC, external VRAM,
PCIe, board pinout, silicon test, GPU application driver, FPS result or
RTX 6090 performance. A continuous scanout consumer must examine
`scan_rsp_epoch` and discard/finish a frame itself when an epoch
changes; P209 does **not** guarantee automatic tear-free frame-boundary
handoff. A later milestone must implement that contract.
