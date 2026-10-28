# P203: tagged controller interface with commit-precise write retirement

## The problem solved

P197/P199 count each accepted physical-bank write as a committed frame
word. A conventional memory-controller **request acceptance** is not the
same as a write committed to backing memory. Making the request handshake
look like a commit would permit a frame to publish before its data is
actually stored. P203 introduces a synthesizable bridge that preserves
that distinction.

## Synthesizable boundary

Each physical bank has a P202 guard followed by the new P203 bridge:

- A READ is accepted upstream when its tagged controller request is
  accepted. A matching tagged READ response arrives later; unsolicited
  and mismatched responses are never returned as valid pixels.
- A WRITE request can be accepted by the controller without causing any
  upstream `cmd_ready`. The bridge holds the command and asserts
  upstream `cmd_ready` **only when its matching, successful controller
  WRITE COMMIT acknowledgement arrives**. Failed writes are never
  counted toward P199's publication threshold.
- A write command must remain stable until its acknowledgement. An
  early release/mutation, wrong bank, response-ID mismatch, unsolicited
  response, controller error or timeout causes a sticky fail-closed
  state. Missing read responses additionally return a **single error
  response** upstream, so P202/P200 can close the read lease.
- After reset, no requests are sent until the controller explicitly
  acknowledges `ctrl_flush_req` with `ctrl_flush_ack`; this is the
  required cancellation/quiescence contract for any physical backend.
  A controller must not acknowledge flush while old responses could
  still be confused with a new transaction.
- Every accepted transaction receives an incrementing ID. The bridge
  refuses wraparound (requires flush/reset) rather than silently
  reusing an ID within a session.
- Controller responses use independent `valid`/`ready` signaling;
  the bridge accepts one outstanding request per bank. This is a
  deliberately small command adapter, not a full AXI implementation.

## Evidence required by P203 CI

1. A new **simulation-only** tagged controller shim wraps P196's
   in-memory 48-bit banks. Its WRITE COMMIT reply is issued only after
   the P196 model actually accepted the write. The full two-frame
   P175→P198→P195→P197→P200→P202→P203 pipeline must verify
   **131,072 actual 48-bit commits**, **200** reads of the previous
   published frame while the second is staging, two atomic publication
   events, and reset revocation.
2. Independent synthetic-controller negative RTL tests must verify
   delayed tagged reads, request-vs-commit timing, mismatched IDs,
   read/write timeouts, a one-shot read-error response, mutated
   in-flight write, unsolicited/stale reply, wrong physical bank and
   failed write COMMIT.
3. Yosys synthesize `a0_p203_tagged_controller_bridge` with
   `check -assert`, preserve logs on failure, no skips/retries.
   The full P202/P126/P127 inherited gates must remain green.

## Important limits

The P196 backing banks and the P203 controller shim used in integration
are **simulation-only**. There is no DDR PHY, PCIe endpoint, hardware
VRAM, board-level memory timing, FPGA place-and-route proof, or GPU FPS.
The flush acknowledgement is an *assumed controller guarantee* that
must be verified on a real implementation. This work does not claim
fault-free physical timing or production throughput.

## Merge protocol

Draft, stacked on P202 (#79), P201 (#78), and ancestors. The full
exact-head test gates and independent review are required. No merge
without explicit owner approval.
