# P208: verified full-frame publication fence over two real on-chip EBR banks

P207 provides **two independent scrubbed hardware EBR banks**, one fully
synthesizable P206/P205/P203 tagged-COMMIT controller per bank, sharing a
29-bit host byte register interface.

P208 adds a synthesizable **publication metadata fence** around the unmodified
P207 top. It does not merely count writes; for each bank it tracks a
`WORDS`-bit map of **unique physical word addresses**. A bit is set only
when the host has submitted a WRITE, subsequently observed actual P203 DONE
and error=0, and acknowledged that DONE. Duplicate writes to one address
cannot fill any other bit. The frame is publishable only after all `WORDS`
unique addresses have received validated COMMIT results.

Default geometry: **two 1024×48-bit hardware EBR banks**, 98,304 RAM bits,
29 external host interface bits. Hardware also stores up to 2,048 commit
coverage bits plus an epoch counter. No simulation-only P196 memory is used
in the new P208 test.

## Register contract

P207's host register map is unchanged, including `0x30` for selecting the
transaction bank. New P208 registers:

| Address | Access | Meaning |
| --- | --- | --- |
| `0x31` | W | Write `0x01` to publish the selected **fully committed** bank. No other write value accepted |
| `0x32` | R | bit0 published front valid; bit1 front bank; bit2 host has staged a command; bit3 selected bank has complete commit coverage |
| `0x33` | R | selected transaction bank (0/1) |
| `0x34..0x37` | R | 32-bit monotonically increasing publication epoch, little-endian |

The publish command is allowed only when no staged or pending write,
both P207 banks are idle, every selected bank address is covered by a
successful write COMMIT, the selected bank differs from the current front,
and the epoch has not wrapped. An invalid publish sets a **sticky fault**.
The front bank is then write-locked: attempts to stage a WRITE or alter
pixel payload bytes while that bank is selected fault without forwarding
the operation to P207. Read commands against the published front remain
supported through the same host interface.

On each successful publish the old front is the new writable back and its
commit coverage is cleared, so a subsequent publication needs another
complete frame. Physical EBR data is retained until an actual overwrite or
the already-established reset scrub. Reset also clears the publisher's
epoch and front-valid flag.

A host write is counted only if it actually observed DONE=1 and error=0
before ACK; an early or invalid ACK cannot fake a completed frame. P207's
own controller and range/tag checks continue to fail closed.

## Test contracts

1. Real Icarus RTL test **twice**, with `WORDS=8` and full
   `WORDS=1024`: duplicate writes never satisfy unique coverage,
   all distinct addresses do, two complete frames publish in order,
   immutable old front remains readable while new back is filled,
   published front is write-locked, and reset clears metadata and both RAMs.
2. Re-run P207's 8/1024 two-physical-bank tests and inherited P206
   embedded RAM, P205 byte mailbox, P203 tagged fault injection and
   real P175 131,072-word two-frame export.
3. Require actual Yosys ECP5 synthesis, zero structural errors, at least
   **six DP16KD EBR**, exactly **29 top-level external I/O bits**, mapped
   LUT4 and TRELLIS_FF, and real nextpnr ECP5-85K CABGA381 speed6
   place-and-route with Fmax ≥10 MHz. Do not skip, hide or retry unchanged
   failed heads. Preserve logs/artifacts on first failure.

## Deliberate limits

**Publication is metadata and write-protection only.** No independent
scanout DMA/reader, pixel/video timing, beam pointer, HDMI/DisplayPort,
double-buffered framebuffer display, PCIe link, DDR/VRAM PHY, real board
pin constraints, silicon measurement, GPU application driver or FPS exists
here. Reading the front through the existing host bus is sequential,
not concurrent with host writing the back. This is a necessary *fence*
for later true scanout, not a claim of completed scanout.
