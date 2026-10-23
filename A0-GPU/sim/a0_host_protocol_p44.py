"""P44 versioned, little-endian byte protocol for the P43 SOFTWARE reference.

This is a host/device-interface *proposal*, not an existing RTL DMA/PCIe bus.
All unused fields are zero and reserved; CRC-32 protects the entire header.
"""
from dataclasses import dataclass
import struct
import zlib
from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, INVALID, Command

VERSION = 1
COMMAND_MAGIC = b'A0GC'
RESULT_MAGIC = b'A0GR'
COMMAND_HEAD = struct.Struct('<4sBBHI6hI')  # 28 bytes
COMMAND_FRAME = 32  # head + crc32
RESULT_HEAD = struct.Struct('<4sBBHI')  # 12 bytes
RESULT_FRAME = 16
SUCCESS, COMMAND_ERROR, TIMEOUT = range(3)

class ProtocolError(ValueError):
    pass

def _crc(head: bytes) -> bytes:
    return struct.pack('<I', zlib.crc32(head) & 0xffffffff)

def _int(name, value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ProtocolError(f'{name} outside [{minimum}, {maximum}]')

def encode_command(command: Command) -> bytes:
    _int('opcode', command.opcode, 0, 3)
    _int('tag', command.tag, 0, 65535)
    _int('color', command.color, 0, 0xffffff)
    if not isinstance(command.vertices, (tuple, list)) or len(command.vertices) != 6:
        raise ProtocolError('exactly 6 vertices coordinates required')
    for i, coord in enumerate(command.vertices):
        _int(f'coord[{i}]', coord, -32768, 32767)
    if command.opcode != TRIANGLE and any(command.vertices):
        raise ProtocolError('non-TRIANGLE requires zero vertices')
    if command.opcode in (PRESENT, INVALID) and command.color != 0:
        raise ProtocolError('PRESENT/INVALID requires zero color')
    head = COMMAND_HEAD.pack(COMMAND_MAGIC, VERSION, command.opcode,
                             command.tag, command.color, *command.vertices, 0)
    return head + _crc(head)

def decode_command(frame: bytes) -> Command:
    if len(frame) != COMMAND_FRAME:
        raise ProtocolError('command length must be 32')
    if frame[:4] != COMMAND_MAGIC or frame[4] != VERSION:
        raise ProtocolError('bad command magic/version')
    if frame[28:] != _crc(frame[:28]):
        raise ProtocolError('command CRC32 mismatch')
    _, _, opcode, tag, color, *rest = COMMAND_HEAD.unpack(frame[:28])
    verts, reserved = rest[:6], rest[6]
    if reserved:
        raise ProtocolError('reserved bytes must be zero')
    command = Command(opcode, tag, color, tuple(verts))
    # Centralize canonical payload constraints for both directions.
    if encode_command(command) != frame:
        raise ProtocolError('noncanonical command')
    return command

@dataclass(frozen=True)
class Result:
    status: int
    tag: int
    cycles: int

    @property
    def ok(self):
        return self.status == SUCCESS

def encode_result(result: Result) -> bytes:
    _int('status', result.status, 0, 2)
    _int('tag', result.tag, 0, 65535)
    _int('cycles', result.cycles, 0, 0xffffffff)
    head = RESULT_HEAD.pack(RESULT_MAGIC, VERSION, result.status,
                            result.tag, result.cycles)
    return head + _crc(head)

def decode_result(frame: bytes) -> Result:
    if len(frame) != RESULT_FRAME:
        raise ProtocolError('result length must be 16')
    if frame[:4] != RESULT_MAGIC or frame[4] != VERSION or frame[12:] != _crc(frame[:12]):
        raise ProtocolError('bad result magic/version/CRC32')
    _, _, status, tag, cycles = RESULT_HEAD.unpack(frame[:12])
    result = Result(status, tag, cycles)
    encode_result(result)  # validates defined status range
    return result

class CommandStreamDecoder:
    """Incremental decoder; malformed data is dropped, NEVER dispatched.

    A valid frame may be fragmented arbitrarily. For corrupted frames, shift
    to the next recognizable magic; this is not an exactly-once transport.
    """
    def __init__(self):
        self.buffer = bytearray()
        self.invalid_frames = 0
        self.dropped_bytes = 0

    def feed(self, data: bytes) -> list[Command]:
        if not isinstance(data, bytes):
            raise TypeError('feed requires bytes')
        self.buffer.extend(data)
        commands = []
        while True:
            pos = self.buffer.find(COMMAND_MAGIC)
            if pos < 0:
                n = max(0, len(self.buffer) - (len(COMMAND_MAGIC)-1))
                del self.buffer[:n]
                self.dropped_bytes += n
                return commands
            if pos:
                del self.buffer[:pos]
                self.dropped_bytes += pos
            if len(self.buffer) < COMMAND_FRAME:
                return commands
            try:
                cmd = decode_command(bytes(self.buffer[:COMMAND_FRAME]))
            except ProtocolError:
                self.invalid_frames += 1
                del self.buffer[0]
                self.dropped_bytes += 1
                continue
            commands.append(cmd)
            del self.buffer[:COMMAND_FRAME]
