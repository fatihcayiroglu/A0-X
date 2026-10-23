"""P55 independent DIRECT graphics reference, not HDL or physical GPU evidence.

This intentionally does not import P38/P39/P42/P43 raster or framebuffer code.
Rasterization uses exact rational pixel centers and the y-down top/left rule.
Bank swaps follow the published two-bank P42 logical framebuffer contract.
"""
from __future__ import annotations
from fractions import Fraction
import hashlib
import zlib


def _covered(a, b, c, x, y):
    winding = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])
    if not winding:
        return False
    if winding < 0:
        b, c = c, b
    px, py = Fraction(2*x+1, 2), Fraction(2*y+1, 2)
    for u, v in ((a,b),(b,c),(c,a)):
        signed_area = (v[0]-u[0])*(py-u[1]) - (v[1]-u[1])*(px-u[0])
        if signed_area < 0:
            return False
        if signed_area == 0 and not (v[1] < u[1] or (v[1] == u[1] and v[0] > u[0])):
            return False
    return True


def render_commands(width, height, commands):
    """Return per-PRESENT visible-frame CRC and SHA using independent logic.

    commands: iterable of (name, canonical P44 Command) pairs. Only accepted
    successful commands belong here; this oracle rejects unsupported states.
    """
    if type(width) is not int or type(height) is not int or not (1 <= width <= 32767 and 1 <= height <= 32767 and width * height <= 65536):
        raise ValueError('invalid P42 dimensions')
    banks = [None, None]  # None means SRAM not initialized, not black.
    front = 0
    frames = []
    for op, command in commands:
        back = 1 - front
        if op == 'CLEAR':
            banks[back] = [command.color] * (width * height)
        elif op == 'TRIANGLE':
            if banks[back] is None:
                raise ValueError('TRIANGLE before initialized render bank')
            x0,y0,x1,y1,x2,y2 = command.vertices
            a,b,c = (x0,y0),(x1,y1),(x2,y2)
            for y in range(height):
                for x in range(width):
                    if _covered(a,b,c,x,y):
                        banks[back][y*width+x] = command.color
        elif op == 'PRESENT':
            if banks[back] is None:
                raise ValueError('PRESENT before initialized render bank')
            front = back
            colors = banks[front]
            # P44 RGB bytes are R,G,B; P47 CRC is over B,G,R.
            rgb = bytes(channel for color in colors
                        for channel in ((color >> 16) & 255, (color >> 8) & 255, color & 255))
            bgr = bytes(channel for color in colors
                        for channel in (color & 255, (color >> 8) & 255, (color >> 16) & 255))
            frames.append({'present_tag':command.tag,
                           'frame_crc32':zlib.crc32(bgr) & 0xffffffff,
                           'rgb_sha256':hashlib.sha256(rgb).hexdigest()})
        else:
            raise ValueError('unsupported opcode in P55 oracle')
    return frames
