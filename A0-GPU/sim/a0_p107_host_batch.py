"""P107 strict mixed P44-v1/P106-v2 batch compiler and capture auditor.

Software-only host tooling. The plan MUST contain *independently supplied*
expected frame CRCs; the capture is never used as its own golden oracle.
No PCIe/device I/O or hardware-level replay protection is provided.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import re
from typing import Any

from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, Command
from a0_host_extended_p106 import HostDraw, decode_host_command, encode_extended_triangle
from a0_host_protocol_p44 import ProtocolError, encode_command
from a0_host_stream_p49 import HostStreamDecoder
from a0_p102_fragment_reference import FragmentState

SCHEMA = 'A0-P107-SESSION-v1'
MAX_FRAMES = 128
MAX_COMMANDS = 4096


def _keys(value: Any, exact: set[str], label: str) -> dict:
    if type(value) is not dict or set(value) != exact:
        raise ValueError(f'{label}: required keys are {sorted(exact)}')
    return value


def _u(label: str, value: Any, limit: int) -> int:
    if type(value) is not int or value < 0 or value > limit:
        raise ValueError(f'{label}: expected unsigned integer <= {limit}')
    return value


def _crc(value: Any) -> int:
    if type(value) is int:
        return _u('expected_crc32', value, 0xffffffff)
    if type(value) is str and re.fullmatch(r'0x[0-9a-fA-F]{8}', value):
        return int(value[2:], 16)
    raise ValueError('expected_crc32: expected u32 or exactly 0x followed by eight hex digits')


@dataclass(frozen=True)
class CompiledSession:
    wire: bytes
    draws: tuple[HostDraw, ...]
    expected_crcs: tuple[int, ...]
    width: int
    height: int
    sha256: str

    @property
    def command_count(self) -> int:
        return len(self.draws)

    def manifest(self) -> dict:
        return {'schema': SCHEMA, 'commands': self.command_count,
                'frames': len(self.expected_crcs), 'width': self.width,
                'height': self.height, 'command_sha256': self.sha256,
                'golden_crc_origin': 'independently supplied by plan; not generated from capture',
                'rtl_qualified': False}


def compile_plan(plan: Any) -> CompiledSession:
    """Turn a fresh-reset, frame-grouped plan into canonical command bytes.

    Every frame starts with CLEAR and ends with PRESENT. Tags may not be
    reused inside the reset epoch; no claim of reliable retransmission.
    """
    _keys(plan, {'schema','width','height','reset_epoch','frames'}, 'session')
    if plan['schema'] != SCHEMA or plan['reset_epoch'] is not True:
        raise ValueError('P107 requires exact schema and an explicitly fresh reset epoch')
    w = _u('width', plan['width'], 32767)
    h = _u('height', plan['height'], 32767)
    if not w or not h or w * h > 65536:
        raise ValueError('unsupported framebuffer geometry')
    frames = plan['frames']
    if type(frames) is not list or not 1 <= len(frames) <= MAX_FRAMES:
        raise ValueError('expected 1..128 frame descriptions')
    wires = []
    draws = []
    golden = []
    seen = set()

    def append(command: Command, *, extended: HostDraw | None = None):
        if command.tag in seen:
            raise ValueError(f'duplicate tag in reset epoch: {command.tag}')
        encoded = encode_extended_triangle(extended) if extended is not None else encode_command(command)
        if decode_host_command(encoded).command != command:
            raise AssertionError('host round-trip invariant failed')
        seen.add(command.tag)
        draws.append(decode_host_command(encoded))
        wires.append(encoded)
        if len(draws) > MAX_COMMANDS:
            raise ValueError('session command count exceeds 4096')

    for index, frame in enumerate(frames):
        _keys(frame, {'clear','draws','present_tag','expected_crc32'}, f'frame {index}')
        clear = _keys(frame['clear'], {'tag','color'}, f'frame {index}.clear')
        _u('clear_tag', clear['tag'], 65535)
        _u('clear_color', clear['color'], 0xffffff)
        append(Command(CLEAR, clear['tag'], clear['color'], (0,)*6))
        commands = frame['draws']
        if type(commands) is not list:
            raise ValueError('draws must be a list')
        for item in commands:
            if type(item) is not dict or 'version' not in item:
                raise ValueError('draw entry must be a versioned object')
            version = _u('draw.version', item['version'], 2)
            if version == 1:
                _keys(item, {'version','tag','color','vertices'}, 'v1 draw')
            elif version == 2:
                _keys(item, {'version','tag','color','vertices','depth','depth_op',
                             'depth_write','blend','alpha','scissor'}, 'v2 draw')
            else:
                raise ValueError('unsupported draw version')
            verts = item['vertices']
            if type(verts) is not list or len(verts) != 6:
                raise ValueError('vertices must have exactly six coordinates')
            if any(type(v) is not int or not -32768 <= v <= 32767 for v in verts):
                raise ValueError('vertices must contain signed 16-bit integers')
            _u('draw.tag', item['tag'], 65535)
            _u('draw.color', item['color'], 0xffffff)
            command = Command(TRIANGLE, item['tag'], item['color'], tuple(verts))
            if version == 1:
                append(command)
                continue
            _u('depth', item['depth'], 0xffffff)
            _u('depth_op', item['depth_op'], 3)
            _u('alpha', item['alpha'], 255)
            if type(item['depth_write']) is not bool or type(item['blend']) is not bool:
                raise ValueError('depth_write and blend must be booleans')
            scissor = item['scissor']
            if scissor is not None:
                if type(scissor) is not list or len(scissor) != 4:
                    raise ValueError('scissor must be null or an array of four u16')
                scissor = tuple(_u('scissor coordinate', v, 65535) for v in scissor)
            state = FragmentState(depth_op=item['depth_op'],
                                  depth_write=item['depth_write'],
                                  blend=item['blend'], alpha=item['alpha'],
                                  scissor=scissor)
            append(command, extended=HostDraw(command, item['depth'], state))
        tag = _u('present_tag', frame['present_tag'], 65535)
        append(Command(PRESENT, tag, 0, (0,)*6))
        golden.append(_crc(frame['expected_crc32']))
    wire = b''.join(wires)
    return CompiledSession(wire, tuple(draws), tuple(golden),w,h,
                           hashlib.sha256(wire).hexdigest())


def audit_capture(session: CompiledSession, capture: bytes, *, sent_wire: bytes | None = None,
                  chunk_size: int = 17) -> dict:
    """Strict packet-level audit in a single known-reset epoch, lossless only.

    Results and frames may be interleaved, but each lane's order is preserved.
    Does not prove physical provenance or correctness of supplied goldens.
    """
    if not isinstance(session, CompiledSession):
        raise TypeError('compiled session required')
    if sent_wire is not None:
        if type(sent_wire) is not bytes or sent_wire != session.wire:
            raise ValueError('sent host command stream differs from compiled plan')
    if type(capture) is not bytes:
        raise TypeError('binary capture required')
    if type(chunk_size) is not int or not 1 <= chunk_size <= 65536:
        raise ValueError('invalid chunk size')
    decoder = HostStreamDecoder()
    decoded = []
    for at in range(0, len(capture), chunk_size):
        decoded.extend(decoder.feed(capture[at:at + chunk_size]))
    finish = decoder.finish()
    if any(finish[key] for key in ('discarded_bytes','invalid_candidates','incomplete_tail_bytes')):
        raise ValueError('capture is corrupt, truncated or contains unexpected bytes')
    results = [event for event in decoded if event['kind'] == 'result']
    frames = [event for event in decoded if event['kind'] == 'frame']
    if len(results) != len(session.draws):
        raise ValueError('missing or extra result packets')
    if len(frames) != len(session.expected_crcs):
        raise ValueError('missing or extra frame telemetry packets')
    for i, (result, draw) in enumerate(zip(results, session.draws)):
        if result['tag'] != draw.command.tag or result['error']:
            raise ValueError(f'command {i} tag/status mismatch')
    for i, (frame, golden) in enumerate(zip(frames, session.expected_crcs)):
        if frame['error'] or frame['frame_crc'] != golden:
            raise ValueError(f'frame {i} error or image CRC mismatch')
        if (frame['sequence'],frame['good'],frame['bad'],
            frame['aborted'],frame['dropped']) != (i & 65535, i+1, 0, 0, 0):
            raise ValueError(f'frame {i} sequence/counter/drop mismatch')
    if finish['decoded_packets'] != len(session.draws) + len(session.expected_crcs):
        raise ValueError('unexpected capture decoder accounting')
    return {'status':'PASS','commands':len(results),'frames':len(frames),
            'capture_bytes':len(capture),'command_sha256':session.sha256,
            'requires_fresh_reset':True,'lossless_host_capture_required':True,
            'hardware_execution_proven':False}
