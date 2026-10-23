#!/usr/bin/env python3
"""P44 local-host command playback over a binary reference transport.

Usage: python tools/a0_host_p44.py --script examples/p44_triangle.json \
        --output /tmp/a0.png --receipt /tmp/a0.json
Not a GPU driver, PCIe endpoint, RTL simulator, or manufactured GPU output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, INVALID, Command
from a0_host_protocol_p44 import (ProtocolError, SUCCESS, COMMAND_ERROR, TIMEOUT,
                                  decode_result, encode_command)
from a0_host_runtime_p44 import P44SoftwareDevice, png_rgb

NAMES = {'CLEAR': CLEAR, 'TRIANGLE': TRIANGLE, 'PRESENT': PRESENT, 'INVALID': INVALID}
MAX_SCRIPT_BYTES = 1024 * 1024
MAX_COMMANDS = 10000

def _dict_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ProtocolError(f'duplicate JSON key: {key}')
        out[key] = value
    return out

def load_script(path: Path) -> dict:
    if path.stat().st_size > MAX_SCRIPT_BYTES:
        raise ProtocolError('command script exceeds 1 MiB')
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_dict_pairs)

def _strict_int(name, v, low, high):
    if type(v) is not int or v < low or v > high:
        raise ProtocolError(f'{name} must be integer in [{low},{high}]')
    return v

def _color(value):
    if type(value) is str and len(value) == 7 and value.startswith('#'):
        try:
            return int(value[1:], 16) if all(c in '0123456789abcdefABCDEF' for c in value[1:]) else -1
        except ValueError:
            pass
    if type(value) is int and 0 <= value <= 0xffffff:
        return value
    raise ProtocolError('color must be integer 0..16777215 or #RRGGBB')

def parse_script(obj):
    if not isinstance(obj, dict) or set(obj) != {'width', 'height', 'commands'}:
        raise ProtocolError('script requires exactly width,height,commands')
    w, h = (_strict_int('width', obj['width'], 1, 32767),
            _strict_int('height', obj['height'], 1, 32767))
    if w*h > 65536:
        raise ProtocolError('maximum resolution is 65536 pixels (P42 constraint)')
    rows = obj['commands']
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_COMMANDS:
        raise ProtocolError('commands must contain 1..10000 entries')
    commands, seen = [], set()
    for i, row in enumerate(rows):
        if not isinstance(row, dict) or not {'op', 'tag'} <= set(row):
            raise ProtocolError(f'command {i} requires op and tag')
        op = row['op']
        if type(op) is not str or op not in NAMES:
            raise ProtocolError(f'unknown op in command {i}')
        opcode = NAMES[op]
        legal = {'op', 'tag'} | ({'color'} if opcode in (CLEAR, TRIANGLE) else set()) | ({'vertices'} if opcode == TRIANGLE else set())
        if set(row) != legal:
            raise ProtocolError(f'command {i} must have exactly {sorted(legal)}')
        tag = _strict_int(f'tag[{i}]', row['tag'], 0, 65535)
        if tag in seen:
            raise ProtocolError(f'duplicate tag {tag}; ambiguous receipt')
        seen.add(tag)
        color = _color(row['color']) if 'color' in row else 0
        vertices = (0,)*6
        if opcode == TRIANGLE:
            v = row['vertices']
            if not isinstance(v, list) or len(v) != 3 or any(not isinstance(p, list) or len(p) != 2 for p in v):
                raise ProtocolError('vertices must be three [x,y] pairs')
            vertices = tuple(_strict_int(f'vertex[{i}]', n, -32768, 32767) for p in v for n in p)
        command = Command(opcode, tag, color, vertices)
        encode_command(command)  # protocol-level validation
        commands.append((op, command))
    return w, h, commands

def replay(obj, *, fragment_size=7, max_cycles=None):
    w, h, commands = parse_script(obj)  # validate entire script before effects
    _strict_int('fragment_size', fragment_size, 1, 1024)
    device = P44SoftwareDevice(w, h, max_cycles=max_cycles)
    receipts = []
    for op, command in commands:
        packet = encode_command(command)
        responses = bytearray()
        for pos in range(0, len(packet), fragment_size):
            responses.extend(device.receive(packet[pos:pos+fragment_size]))
        if len(responses) != 16:
            raise RuntimeError('missing/duplicated completion packet')
        reply = decode_result(bytes(responses))
        if reply.tag != command.tag:
            raise RuntimeError('host completion tag mismatch')
        receipts.append({'op':op, 'tag': reply.tag,
                         'status': ('OK', 'COMMAND_ERROR', 'TIMEOUT')[reply.status],
                         'cycles': reply.cycles})
        if reply.status == TIMEOUT:
            break
    visible = device.adapter.display.display_initialized
    rgb = device.visible_rgb() if visible else None
    return {'kind':'P44_SOFTWARE_REFERENCE_ONLY', 'protocol_version':1,
            'resolution':[w,h], 'commands': receipts,
            'commands_requested':len(commands), 'commands_completed':len(receipts),
            'framebuffer_visible': visible,
            'rgb_sha256': hashlib.sha256(rgb).hexdigest() if rgb is not None else None}, rgb

def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--script', required=True, type=Path)
    ap.add_argument('--output', type=Path, help='optional PNG destination (requires PRESENT)')
    ap.add_argument('--receipt', type=Path, help='optional JSON receipt output')
    ap.add_argument('--fragment-size', type=int, default=7)
    args=ap.parse_args(argv)
    try:
        doc=load_script(args.script)
        report, rgb=replay(doc, fragment_size=args.fragment_size)
        if args.output and rgb is None:
            raise ProtocolError('requested image output but no visible PRESENTed frame')
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(png_rgb(*report['resolution'], rgb))
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(report, indent=2)+'\n',encoding='utf-8')
        print(json.dumps(report, indent=2))
        if any(row['status'] != 'OK' for row in report['commands']):
            return 1
        return 0
    except (OSError, ValueError, RuntimeError) as e:
        print(f'P44 ERROR: {e}',file=sys.stderr)
        return 2

if __name__=='__main__':
    raise SystemExit(main())
