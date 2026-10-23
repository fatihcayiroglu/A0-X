"""P38 experimental triangle coverage model, not hardware execution.

Pixel centers are (x+1/2, y+1/2), with integer screen-coordinate
vertices and positive-area normalization. A y-down top-left rule excludes
bottom/right shared boundaries and includes top/left boundaries.
"""
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Triangle:
    a: tuple[int, int]
    b: tuple[int, int]
    c: tuple[int, int]


def edge2(a: tuple[int, int], b: tuple[int, int], x: int, y: int) -> int:
    """Twice the edge function, evaluated at (x+1/2,y+1/2)."""
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    return dx * (2 * y + 1 - 2 * a[1]) - dy * (2 * x + 1 - 2 * a[0])


def orient(a: tuple[int, int], b: tuple[int, int], c: tuple[int, int]) -> int:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def top_left(a: tuple[int, int], b: tuple[int, int]) -> bool:
    return b[1] < a[1] or (b[1] == a[1] and b[0] > a[0])


def normalize(t: Triangle) -> Triangle | None:
    area = orient(t.a, t.b, t.c)
    if area == 0:
        return None
    if area < 0:
        return Triangle(t.a, t.c, t.b)
    return t


def covers_pixel(t: Triangle, x: int, y: int) -> bool:
    t = normalize(t)
    if t is None:
        return False
    for a, b in ((t.a, t.b), (t.b, t.c), (t.c, t.a)):
        v = edge2(a, b, x, y)
        if v < 0 or (v == 0 and not top_left(a, b)):
            return False
    return True


def rasterize(t: Triangle, width: int, height: int) -> list[tuple[int, int]]:
    if not (1 <= width <= 32767 and 1 <= height <= 32767):
        raise ValueError('frame dimensions must be 1..32767')
    for point in (t.a, t.b, t.c):
        if not all(-32768 <= n <= 32767 for n in point):
            raise ValueError('hardware vertex coordinates must be signed 16-bit')
    return [(x, y) for y in range(height) for x in range(width)
            if covers_pixel(t, x, y)]


class CoverageEngine:
    """Cycle-level valid/ready functional contract for RTL comparisons.

    tick() models the state immediately *after* one rising edge. The returned
    output is the handshake observed on that edge. Emission is row-major.
    """
    def __init__(self, width: int, height: int):
        if not (1 <= width <= 32767 and 1 <= height <= 32767):
            raise ValueError('frame dimensions must be 1..32767')
        self.width, self.height = width, height
        self.reset()

    def reset(self) -> None:
        self.triangle: Triangle | None = None
        self.x = 0
        self.y = 0

    @property
    def tri_ready(self) -> bool:
        return self.triangle is None

    @property
    def pixel_valid(self) -> bool:
        return self.triangle is not None and covers_pixel(self.triangle, self.x, self.y)

    @property
    def pixel(self) -> tuple[int, int]:
        return self.x, self.y

    def tick(self, *, tri: Triangle | None = None, pixel_ready: bool = True,
             rst_n: bool = True) -> tuple[tuple[int, int] | None, bool]:
        """Return (accepted_pixel, done_pulse) for one edge."""
        if not rst_n:
            self.reset()
            return None, False
        if self.triangle is None:
            if tri is not None:
                for point in (tri.a, tri.b, tri.c):
                    if any(n < -32768 or n > 32767 for n in point):
                        raise ValueError('vertex outside signed 16-bit range')
                n = normalize(tri)
                if n is None:
                    return None, True
                self.triangle = n
                self.x = self.y = 0
            return None, False
        was_valid = self.pixel_valid
        accepted = self.pixel if was_valid and pixel_ready else None
        done = False
        if not was_valid or pixel_ready:
            if self.x == self.width - 1 and self.y == self.height - 1:
                self.reset()
                done = True
            elif self.x == self.width - 1:
                self.x = 0
                self.y += 1
            else:
                self.x += 1
        return accepted, done
