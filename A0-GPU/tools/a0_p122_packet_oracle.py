#!/usr/bin/env python3
"""P122 wire-level *software oracle* for the P118 A0GF/A0GL packets.

This is independent reference encoding, not RTL simulation or silicon proof.
The CRC32 covers the 28-byte wire payload. All integers are little-endian.
"""
from __future__ import annotations
import argparse
import json
import struct
import sys
import zlib

PACKET_LENGTH = 32


def uint(value: int, bits: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not (0 <= value < (1 << bits)):
        raise ValueError(f"expected unsigned {bits}-bit integer")
    return value


def _finish(payload: bytes) -> bytes:
    assert len(payload) == 28
    return payload + struct.pack('<I', zlib.crc32(payload) & 0xFFFFFFFF)


def frame(*, sequence: int, frame_crc: int, error: bool = False,
          good: int = 0, bad: int = 0, aborted: int = 0, dropped: int = 0) -> bytes:
    if type(error) is not bool:
        raise ValueError('error must be bool')
    payload = struct.pack('<IBBHIIIII', 0x46473041, 1, int(error),
                          uint(sequence, 16), uint(frame_crc, 32), uint(good, 32),
                          uint(bad, 32), uint(aborted, 32), uint(dropped, 32))
    return _finish(payload)


def loss_notice(*, sequence: int, dropped: int, good: int = 0, bad: int = 0,
                aborted: int = 0) -> bytes:
    payload = struct.pack('<IBBHIIIII', 0x4C473041, 1, 1, uint(sequence, 16),
                          uint(dropped, 32), uint(good, 32), uint(bad, 32),
                          uint(aborted, 32), 0)
    return _finish(payload)


def decode(packet: bytes) -> dict:
    if len(packet) != PACKET_LENGTH:
        raise ValueError('packet must be 32 bytes')
    expected_crc = zlib.crc32(packet[:28]) & 0xFFFFFFFF
    (wire_crc,) = struct.unpack_from('<I', packet, 28)
    if wire_crc != expected_crc:
        raise ValueError('CRC32 mismatch')
    magic, version, flags, sequence, a, b, c, d, e = struct.unpack('<IBBHIIIII', packet[:28])
    if version != 1:
        raise ValueError('unsupported version')
    if magic == 0x46473041 and flags in (0, 1):
        return dict(type='frame', sequence=sequence, error=bool(flags),
                    frame_crc=a, good=b, bad=c, aborted=d, dropped=e)
    if magic == 0x4C473041 and flags == 1 and e == 0:
        return dict(type='loss', sequence=sequence, dropped=a,
                    good=b, bad=c, aborted=d)
    raise ValueError('invalid packet header/reserved fields')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packet_hex', help='Exactly 32 bytes of wire hex')
    args = parser.parse_args()
    try:
        data = bytes.fromhex(args.packet_hex)
        print(json.dumps(decode(data), sort_keys=True))
    except ValueError as exc:
        print(f'P122_PACKET_INVALID: {exc}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
