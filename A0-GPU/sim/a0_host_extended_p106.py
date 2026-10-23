"""P106 experimental P44-compatible, 56-byte v2 *TRIANGLE* protocol.

This is a canonical logical-host protocol, NOT an RTL/PCIe qualification.
V1 commands remain 32 bytes and retain P105 legacy fragment defaults.
V2 extends TRIANGLE only; CLEAR / PRESENT / INVALID stay V1.
"""
from dataclasses import dataclass
import struct
import zlib
from a0_graphics_command_p43 import TRIANGLE, Command
from a0_host_protocol_p44 import (COMMAND_MAGIC, COMMAND_HEAD, ProtocolError,
                                   decode_command, encode_command)
from a0_p102_fragment_reference import FragmentState

EXT_VERSION = 2
EXT_FRAME_SIZE = 56
EXT_PAYLOAD = struct.Struct('<IBBH4H8s')  # depth24, flags, alpha, reserved, scissor, reserved
LEGACY_FRAGMENT = FragmentState(depth_op=0, depth_write=False, blend=False, alpha=255)

@dataclass(frozen=True)
class HostDraw:
    command: Command
    depth: int = 0xffffff
    state: FragmentState = LEGACY_FRAGMENT


def _check_integer(label, value, lo, hi):
    if type(value) is not int or not lo <= value <= hi:
        raise ProtocolError(f'{label} outside [{lo},{hi}]')


def encode_extended_triangle(draw: HostDraw) -> bytes:
    if not isinstance(draw, HostDraw) or not isinstance(draw.command, Command):
        raise ProtocolError('HostDraw required')
    c, s = draw.command, draw.state
    if c.opcode != TRIANGLE:
        raise ProtocolError('v2 supports TRIANGLE only')
    _check_integer('depth', draw.depth, 0, 0xffffff)
    if type(s.depth_write) is not bool or type(s.blend) is not bool:
        raise ProtocolError('boolean depth-write/blend expected')
    _check_integer('depth_op', s.depth_op, 0, 3)
    _check_integer('alpha', s.alpha, 0, 255)
    coords = (0, 0, 0, 0)
    if s.scissor is not None:
        if type(s.scissor) not in (tuple, list) or len(s.scissor) != 4:
            raise ProtocolError('scissor requires 4 values')
        for i, coord in enumerate(s.scissor):
            _check_integer(f'scissor[{i}]', coord, 0, 65535)
        if s.scissor[2] == 0 or s.scissor[3] == 0:
            raise ProtocolError('enabled scissor width/height must be nonzero')
        coords = tuple(s.scissor)
    # Reuse V1 constraints, but don't dispatch a V1 packet.
    encode_command(c)
    flags = (s.depth_op | (int(s.depth_write) << 2) |
             (int(s.blend) << 3) | (int(s.scissor is not None) << 4))
    header = COMMAND_HEAD.pack(COMMAND_MAGIC, EXT_VERSION, TRIANGLE,
                               c.tag, c.color, *c.vertices, 0)
    state_bytes = EXT_PAYLOAD.pack(draw.depth, flags, s.alpha, 0, *coords, b'\0'*8)
    data = header + state_bytes
    assert len(data) == EXT_FRAME_SIZE - 4
    return data + struct.pack('<I', zlib.crc32(data))


def decode_host_command(frame: bytes) -> HostDraw:
    if type(frame) is not bytes:
        raise ProtocolError('bytes required')
    if len(frame) == 32:
        return HostDraw(decode_command(frame))
    if len(frame) != EXT_FRAME_SIZE:
        raise ProtocolError('unsupported command length')
    if frame[:4] != COMMAND_MAGIC or frame[4] != EXT_VERSION:
        raise ProtocolError('bad extended magic/version')
    if zlib.crc32(frame[:52]) != int.from_bytes(frame[52:56], 'little'):
        raise ProtocolError('extended CRC32 mismatch')
    magic, version, opcode, tag, color, *rest = COMMAND_HEAD.unpack(frame[:28])
    verts = tuple(rest[:6]); reserved = rest[6]
    depth, flags, alpha, reserved_short, sx, sy, sw, sh, tail = EXT_PAYLOAD.unpack(frame[28:52])
    if opcode != TRIANGLE or reserved or reserved_short or tail != b'\0'*8:
        raise ProtocolError('noncanonical v2 opcode/reserved')
    if color > 0xffffff or depth > 0xffffff or (flags & ~0x1f):
        raise ProtocolError('noncanonical v2 color/depth/flags')
    scissor = (sx,sy,sw,sh) if flags & 0x10 else None
    if (flags & 0x10 and (not sw or not sh)) or (not flags & 0x10 and (sx or sy or sw or sh)):
        raise ProtocolError('noncanonical v2 scissor')
    draw = HostDraw(Command(opcode,tag,color,verts), depth,
                    FragmentState(depth_op=flags & 3,
                                  depth_write=bool(flags & 4),
                                  blend=bool(flags & 8),alpha=alpha,
                                  scissor=scissor))
    if encode_extended_triangle(draw) != frame:
        raise ProtocolError('noncanonical v2 packet')
    return draw


class ExtendedCommandStreamDecoder:
    """Mixed P44-v1 and P106-v2 stream; fail-closed resynchronization.

    Like P44, malformed candidates are dropped, never dispatched. No claims
    of exactly-once delivery after stream corruption. Buffer is bounded to 55.
    """
    def __init__(self):
        self.buffer = bytearray()
        self.invalid_frames = 0
        self.dropped_bytes = 0

    def feed(self, data: bytes):
        if type(data) is not bytes:
            raise TypeError('feed requires bytes')
        self.buffer.extend(data)
        result=[]
        while True:
            at=self.buffer.find(COMMAND_MAGIC)
            if at < 0:
                n=max(0,len(self.buffer)-3)
                del self.buffer[:n];self.dropped_bytes+=n
                return result
            if at:
                del self.buffer[:at];self.dropped_bytes+=at
            if len(self.buffer)<5:
                return result
            version=self.buffer[4]
            if version not in (1,2):
                self.invalid_frames+=1
                del self.buffer[:1];self.dropped_bytes+=1
                continue
            length=32 if version==1 else 56
            if len(self.buffer)<length:
                return result
            try:
                draw=decode_host_command(bytes(self.buffer[:length]))
            except ProtocolError:
                self.invalid_frames+=1
                del self.buffer[:1];self.dropped_bytes+=1
                continue
            result.append(draw)
            del self.buffer[:length]
