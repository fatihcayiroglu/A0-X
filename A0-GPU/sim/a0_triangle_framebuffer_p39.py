"""Cycle contract for P39's standalone triangle->RGB888 framebuffer prototype.

This reference model is not hardware verification. A clearing transaction after
reset is required to make framebuffer contents defined. The framebuffer is
single-buffered; no real display controller or external DRAM is represented.
"""
from dataclasses import dataclass
from a0_triangle_coverage_p38 import CoverageEngine, Triangle


@dataclass(frozen=True)
class TickResult:
    clear_done: bool = False
    tri_done: bool = False


class FramebufferEngine:
    def __init__(self, width: int, height: int):
        if width < 1 or height < 1 or width > 32767 or height > 32767 or width * height > 65536:
            raise ValueError('P39 dimensions must hold 1..65536 pixels')
        self.width, self.height = width, height
        self.raster = CoverageEngine(width, height)
        self.fb = [None] * (width * height)
        self.clear_active = False
        self.clear_index = 0
        self.clear_color_q = 0
        self.triangle_color_q = 0
        self.initialized = False

    def reset(self) -> None:
        self.raster.reset()
        self.fb = [None] * (self.width * self.height)
        self.clear_active = False
        self.clear_index = 0
        self.initialized = False

    @property
    def clear_ready(self) -> bool:
        return not self.clear_active and self.raster.tri_ready

    @property
    def tri_ready(self) -> bool:
        return self.initialized and self.clear_ready

    @property
    def busy(self) -> bool:
        return self.clear_active or not self.raster.tri_ready

    def read(self, x: int, y: int) -> int:
        if not self.initialized or not (0 <= x < self.width and 0 <= y < self.height):
            return 0
        return self.fb[y * self.width + x]

    def tick(self, *, clear_color: int | None = None,
             tri: Triangle | None = None, tri_color: int = 0,
             rst_n: bool = True) -> TickResult:
        if not rst_n:
            self.reset()
            return TickResult()
        if clear_color is not None and not 0 <= clear_color <= 0xFFFFFF:
            raise ValueError('clear color is not RGB888')
        if not 0 <= tri_color <= 0xFFFFFF:
            raise ValueError('triangle color is not RGB888')
        # The pixel handshake uses the pre-edge registered triangle color.
        if self.clear_active:
            self.fb[self.clear_index] = self.clear_color_q
            if self.clear_index + 1 == len(self.fb):
                self.clear_active = False
                self.initialized = True
                self.clear_index = 0
                return TickResult(clear_done=True)
            self.clear_index += 1
            return TickResult()
        if clear_color is not None and self.clear_ready:
            self.clear_active = True
            self.initialized = False
            self.clear_index = 0
            self.clear_color_q = clear_color
            return TickResult()
        if tri is not None and self.tri_ready:
            self.triangle_color_q = tri_color
            _, done = self.raster.tick(tri=tri)
            return TickResult(tri_done=done)
        pixel, done = self.raster.tick()
        if pixel is not None:
            x, y = pixel
            self.fb[y * self.width + x] = self.triangle_color_q
        return TickResult(tri_done=done)

    def clear(self, color: int) -> None:
        if not self.clear_ready:
            raise RuntimeError('clear not ready')
        self.tick(clear_color=color)
        for _ in range(len(self.fb)):
            result = self.tick()
        assert result.clear_done

    def draw(self, tri: Triangle, color: int) -> None:
        if not self.tri_ready:
            raise RuntimeError('triangle not ready')
        result = self.tick(tri=tri, tri_color=color)
        if result.tri_done:
            return
        for _ in range(len(self.fb)):
            result = self.tick()
        assert result.tri_done

    def ppm(self) -> bytes:
        if not self.initialized:
            raise RuntimeError('framebuffer must first be cleared')
        header = f'P6\n{self.width} {self.height}\n255\n'.encode('ascii')
        return header + b''.join(int(v).to_bytes(3, 'big') for v in self.fb)
