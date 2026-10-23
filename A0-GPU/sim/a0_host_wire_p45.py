"""P45 clock-step SOFTWARE SPEC of the streaming HDL receive interface.

This is NOT an HDL simulator and is never used as evidence of RTL behavior.
It independently calculates CRC32 bit-by-bit and exposes ready/valid backpressure.
"""
from dataclasses import dataclass
from a0_graphics_command_p43 import Command

MAGIC = b'A0GC'


def ieee_crc32(data: bytes) -> int:
    crc = 0xffffffff
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xedb88320 if crc & 1 else 0)
    return (~crc) & 0xffffffff


def parse_candidate(frame: bytes):
    if len(frame) != 32 or frame[:4] != MAGIC or frame[4] != 1:
        return None
    if frame[5] > 3 or frame[11] != 0 or frame[24:28] != b'\0'*4:
        return None
    if frame[5] != 1 and frame[12:24] != b'\0'*12:
        return None
    if frame[5] >= 2 and frame[8:11] != b'\0'*3:
        return None
    if int.from_bytes(frame[28:32], 'little') != ieee_crc32(frame[:28]):
        return None
    coords = tuple(int.from_bytes(frame[i:i+2], 'little', signed=True)
                   for i in range(12, 24, 2))
    return Command(frame[5], int.from_bytes(frame[6:8], 'little'),
                   int.from_bytes(frame[8:11], 'little'), coords)

@dataclass(frozen=True)
class Tick:
    in_ready: bool
    cmd_valid: bool
    cmd: Command | None
    accepted_byte: bool
    dispatched_command: bool

class P45ReceiveSpec:
    def __init__(self):
        self.reset()

    def reset(self):
        self.window = bytearray()
        self.pending = None
        self.invalid_frame_count = 0
        self.accepted = 0
        self.dispatched = []

    def tick(self, *, in_valid=False, in_byte=0, cmd_ready=False, rst_n=True):
        if not rst_n:
            self.reset()
            return Tick(False, False, None, False, False)
        ready = self.pending is None
        old_pending = self.pending
        dispatched = old_pending is not None and cmd_ready
        if dispatched:
            self.dispatched.append(old_pending)
            self.pending = None
            self.window.clear()
        accepted = bool(in_valid and ready)
        if accepted:
            if type(in_byte) is not int or not 0 <= in_byte <= 255:
                raise ValueError('in_byte must be uint8')
            self.accepted += 1
            self.window.append(in_byte)
            if len(self.window) > 32:
                del self.window[0]
            if len(self.window) == 32 and self.window[:4] == MAGIC:
                candidate = parse_candidate(bytes(self.window))
                if candidate is None:
                    self.invalid_frame_count = min(0xffffffff, self.invalid_frame_count + 1)
                else:
                    self.pending = candidate
        return Tick(ready, old_pending is not None, old_pending, accepted, dispatched)
