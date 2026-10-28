# P202: bounded, bank-aware external memory command/response guards

## Hardware contract

P202 places a **synthesizable transport guard on each P200 physical-bank
port**. The command interface remains the existing 48-bit pixel-word
ready/valid protocol; no address translation, data array, memory calibration
or DDR PHY is added.

- Only bank 0's physical `[BASE, BASE+FRAME_WORDS)` and bank 1's
  `[BASE+FRAME_WORDS, BASE+2*FRAME_WORDS)` respectively may be issued
  to their downstream controllers. A wrong-bank command latches failure
  without reaching the backend.
- Writes commit when upstream and backend acknowledge the same command.
  A permanently not-ready backend trips `CMD_STALL_LIMIT`. A bounded
  stall below this limit is legal and must not masquerade as a commit.
- At most one read is outstanding per guard; its reply must be a pulse
  at least one clock after read acceptance. A missing reply triggers
  `READ_TIMEOUT`, a single upstream **error response**, and sticky
  quarantine until reset. This response releases P200/P199's old-bank
  read lease with an explicit error; it does not mean data was returned.
- Unsolicited responses, overlapping bank commands, and backend read
  errors fault closed. Late data is never allowed to escape a faulted
  guard. Reset revokes all in-flight/read/fault state.

## Verification

1. Full real post-render **P175 256×256** two-scene integration is retained
   verbatim except for two new P202 guards inserted between the P200
   synthesizable router and the two **P196 simulation-only** word banks.
   It verifies 131,072 accepted RGB+depth words, 200 published old-bank
   reads during a new capture, exactly 2 autonomous seals/publications,
   and no guard/epoch/router faults.
2. An independent tiny instance injects delayed-but-valid read,
   bounded write stall, lost read response, exact one timeout error,
   late stale response, unsolicited response, wrong-bank address,
   permanent write backpressure, backend error, and overlapping command.
   The first failure is fatal, not skipped, and no failed head is rerun.
3. Icarus RTL and Yosys synthesis/`check -assert` run on GitHub Actions
   at each PR head; logs/artifacts are retained even on a failed run.

## Deliberate limitations

The external `backend_cmd_ready` is still a handshake contract, **not**
a real memory-controller implementation. There are no physical DDR timing
constraints, actual VRAM/FPGA board, PCIe, error-correcting code (ECC),
hardware display scanout or measured FPS. Timeouts are clock-cycle bounds,
not guaranteed real-time wall-clock deadlines. Production integration
needs a transport with transaction identifiers or externally guaranteed
in-order single-read responses, and must verify reset/late-reply behavior
at its actual controller boundary.

## Merge safety

Draft stacked on P201 (#78) -> P200 (#77) and ancestors. All exact-head
jobs must pass, and independent review/owner authorization is required
before any merge. Do not call simulation-only memory "physical VRAM".
