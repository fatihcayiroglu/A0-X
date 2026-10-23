"""P46 independent clock-step SOFTWARE reference for a single-entry RTL TX.

This is neither an HDL simulator nor physical device evidence. It intentionally
uses its own byte packing and bitwise CRC implementation, then tests compare
against the frozen P44 protocol implementation.
"""
from dataclasses import dataclass


def wire_crc32(data: bytes) -> int:
    accumulator = 0xffffffff
    for value in data:
        accumulator ^= value
        for bit in range(8):
            accumulator = (accumulator >> 1) ^ (0xedb88320 if accumulator & 1 else 0)
    return accumulator ^ 0xffffffff


def serialize_result(tag: int, error: bool, cycles: int) -> bytes:
    if type(tag) is not int or not 0 <= tag < 65536:
        raise ValueError('tag must be unsigned 16-bit int')
    if type(error) is not bool:
        raise ValueError('error must be bool')
    if type(cycles) is not int or not 0 <= cycles < (1 << 32):
        raise ValueError('cycles must be unsigned 32-bit int')
    header = bytearray(b'A0GR')
    header.extend((1, int(error)))
    header.extend((tag & 255, tag >> 8))
    header.extend((cycles >> (8 * i)) & 255 for i in range(4))
    checksum = wire_crc32(header)
    return bytes(header) + bytes((checksum >> (8 * i)) & 255 for i in range(4))


@dataclass(frozen=True)
class Edge:
    result_ready: bool
    out_valid: bool
    out_byte: int | None
    accepted_result: bool
    emitted_byte: bool


class P46TransmitSpec:
    """Pre-edge handshakes, state changes on clock edge; reset synchronous."""
    def __init__(self):
        self.reset()

    def reset(self):
        self._frame = None
        self._index = 0
        self.accepted_results = 0
        self.emitted_bytes = 0

    def tick(self, *, result_valid=False, tag=0, error=False,
             cycles=0, out_ready=False, rst_n=True) -> Edge:
        if not rst_n:
            self.reset()
            return Edge(False, False, None, False, False)
        result_ready = self._frame is None
        out_valid = self._frame is not None
        out_byte = self._frame[self._index] if out_valid else None
        accepted_result = bool(result_valid and result_ready)
        emitted_byte = bool(out_valid and out_ready)
        if emitted_byte:
            self.emitted_bytes += 1
            self._index += 1
            if self._index == 16:
                self._frame = None
                self._index = 0
        elif accepted_result:
            self._frame = serialize_result(tag, error, cycles)
            self.accepted_results += 1
        return Edge(result_ready, out_valid, out_byte, accepted_result, emitted_byte)
