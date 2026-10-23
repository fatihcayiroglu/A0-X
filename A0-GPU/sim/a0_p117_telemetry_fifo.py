"""P117 FIFO software reference; explicit PRE-clock-edge outputs.

This tests design intent, NOT SystemVerilog correctness. Compatible with P48
32-byte A0GF frame diagnostics and P49 packet-atomic arbitration.
"""
from collections import deque
from dataclasses import dataclass
from a0_frame_telemetry_p48 import encode_frame


@dataclass(frozen=True)
class FifoEdge:
    valid: bool
    byte: int | None
    emitted: bool
    accepted: bool
    dropped: bool
    count_before: int


class TelemetryFifoSpec:
    def __init__(self, depth=4):
        if type(depth) is not int or depth < 2:
            raise ValueError('depth must be an integer >= 2')
        self.depth = depth
        self.reset()

    def reset(self):
        self.queue = deque()
        self.offset = 0
        self.sequence = 0
        self.dropped = 0

    def tick(self, *, frame_valid=False, error=False, frame_crc=0,
             good=0, bad=0, aborted=0, tx_ready=False, rst_n=True):
        if not rst_n:
            self.reset()
            return FifoEdge(False, None, False, False, False, 0)
        before = len(self.queue)
        valid = bool(self.queue)
        byte = self.queue[0][self.offset] if valid else None
        emit = bool(valid and tx_ready)
        pop = emit and self.offset == 31
        push = bool(frame_valid and (before < self.depth or pop))
        drop = bool(frame_valid and not push)
        # All new packets snapshot counter/sequence values BEFORE this edge.
        new_packet = None
        if push:
            new_packet = encode_frame(sequence=self.sequence, error=error,
                                      frame_crc=frame_crc, good=good, bad=bad,
                                      aborted=aborted, dropped=self.dropped)
        if frame_valid:
            self.sequence = (self.sequence + 1) & 0xffff
        if drop:
            self.dropped = min(self.dropped + 1, 0xffffffff)
        if emit:
            if pop:
                self.queue.popleft()
                self.offset = 0
            else:
                self.offset += 1
        if push:
            self.queue.append(new_packet)
        assert len(self.queue) <= self.depth
        return FifoEdge(valid, byte, emit, push, drop, before)
