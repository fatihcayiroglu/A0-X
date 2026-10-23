"""P48 independent SOFTWARE transaction reference, not HDL simulation.

Two distinct result formats share one byte stream without interleaving:
A0GR/16-byte P46 responses and A0GF/32-byte frame diagnostics.
"""
from dataclasses import dataclass
import struct
import zlib

MAGIC_RESULT = b'A0GR'
MAGIC_FRAME = b'A0GF'


def _u32(v):
    return type(v) is int and 0 <= v <= 0xffffffff


def encode_frame(*, sequence, error, frame_crc, good, bad, aborted, dropped):
    if type(sequence) is not int or not 0 <= sequence <= 65535:
        raise ValueError('sequence must be unsigned 16-bit')
    if type(error) is not bool or not all(_u32(x) for x in (frame_crc, good, bad, aborted, dropped)):
        raise ValueError('bad telemetry field')
    raw = struct.pack('<4sBBHIIIII', MAGIC_FRAME, 1, int(error), sequence,
                      frame_crc, good, bad, aborted, dropped)
    assert len(raw) == 28
    return raw + struct.pack('<I', zlib.crc32(raw))


def decode_host_frames(data: bytes):
    """Strict record decoder: refuse partial, corrupted or unrecognized frames."""
    if not isinstance(data, bytes):
        raise ValueError('stream must be bytes')
    frames = []
    i = 0
    while i < len(data):
        magic = data[i:i+4]
        if magic not in (MAGIC_RESULT, MAGIC_FRAME):
            raise ValueError('unrecognized host frame magic')
        size = 16 if magic == MAGIC_RESULT else 32
        wire = data[i:i+size]
        if len(wire) != size:
            raise ValueError('truncated host frame')
        if zlib.crc32(wire[:-4]) != int.from_bytes(wire[-4:], 'little'):
            raise ValueError('host frame crc mismatch')
        if wire[4] != 1:
            raise ValueError('unsupported host frame version')
        if magic == MAGIC_RESULT:
            if wire[5] > 1:
                raise ValueError('unknown result status')
            frames.append({'kind':'result', 'error':bool(wire[5]),
                           'tag':int.from_bytes(wire[6:8],'little'),
                           'cycles':int.from_bytes(wire[8:12],'little')})
        else:
            if wire[5] > 1:
                raise ValueError('unknown frame telemetry flags')
            seq, crc, good, bad, aborted, dropped = struct.unpack('<HIIIII', wire[6:28])
            frames.append({'kind':'frame', 'error':bool(wire[5]), 'sequence':seq,
                           'frame_crc':crc, 'good':good, 'bad':bad,
                           'aborted':aborted, 'dropped':dropped})
        i += size
    return frames


@dataclass(frozen=True)
class TelemetryEdge:
    valid: bool
    byte: int | None
    emitted: bool
    accepted: bool
    dropped: bool


class TelemetryTxSpec:
    def __init__(self):
        self.reset()

    def reset(self):
        self.packet = None
        self.index = 0
        self.sequence = 0
        self.dropped = 0

    def tick(self, *, frame_valid=False, error=False, frame_crc=0,
             good=0, bad=0, aborted=0, tx_ready=False, rst_n=True):
        if not rst_n:
            self.reset()
            return TelemetryEdge(False,None,False,False,False)
        valid = self.packet is not None
        byte = self.packet[self.index] if valid else None
        emitted = bool(valid and tx_ready)
        accepted = bool(frame_valid and not valid)
        dropped_event = bool(frame_valid and valid)
        # Snapshot uses pre-edge drop counter, as in RTL.
        if accepted:
            new_packet = encode_frame(sequence=self.sequence, error=error,
                                      frame_crc=frame_crc, good=good,
                                      bad=bad, aborted=aborted, dropped=self.dropped)
        if frame_valid:
            self.sequence = (self.sequence + 1) & 65535
        if dropped_event:
            self.dropped = min(self.dropped + 1, 0xffffffff)
        if emitted:
            self.index += 1
            if self.index == 32:
                self.packet = None
                self.index = 0
        elif accepted:
            self.packet = new_packet
            self.index = 0
        return TelemetryEdge(valid,byte,emitted,accepted,dropped_event)


@dataclass(frozen=True)
class ArbiterEdge:
    valid: bool
    byte: int | None
    result_ready: bool
    telemetry_ready: bool
    emitted: bool
    lane: str | None


class FrameArbiterSpec:
    def __init__(self):
        self.reset()

    def reset(self):
        self.lane = None
        self.index = 0

    def tick(self, *, result_valid=False, result_byte=0,
             telemetry_valid=False, telemetry_byte=0,
             host_ready=False, rst_n=True):
        if not rst_n:
            self.reset()
            return ArbiterEdge(False,None,False,False,False,None)
        lane = self.lane
        valid = (result_valid if lane == 'result' else
                 telemetry_valid if lane == 'frame' else False)
        byte = (result_byte if lane == 'result' else
                telemetry_byte if lane == 'frame' else None)
        rready = bool(lane == 'result' and host_ready)
        tready = bool(lane == 'frame' and host_ready)
        emitted = bool(valid and host_ready)
        if lane is None:
            self.lane = 'result' if result_valid else ('frame' if telemetry_valid else None)
            self.index = 0
        elif emitted:
            self.index += 1
            if self.index == (16 if lane == 'result' else 32):
                self.lane = None
                self.index = 0
        return ArbiterEdge(bool(valid), byte if valid else None,
                           rready,tready,emitted,lane)
