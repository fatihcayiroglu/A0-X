"""P40 cycle-level reference for the experimental readout stream.

The registered beat is immutable while stalled. This mirrors the intended P40
ready/valid interface, not a claim that HDL or physical hardware has passed.
Framebuffer data is sampled when the next beat is enqueued, not when consumed.
"""
from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class Beat:
    x: int
    y: int
    color: int
    sof: bool
    eol: bool
    eof: bool


@dataclass(frozen=True)
class Step:
    beat: Beat | None
    accepted: bool
    frame_done: bool


class ScanoutEngine:
    def __init__(self, width: int, height: int):
        if not 1 <= width <= 32767 or not 1 <= height <= 32767 or width * height > 65536:
            raise ValueError('P40 supports dimensions 1..32767, <=65536 total pixels')
        self.width, self.height = width, height
        self.reset()

    def reset(self):
        self.fetch_x = 0
        self.fetch_y = 0
        self.pending = None
        self.frame_done = False

    def peek(self, *, enable: bool = True, initialized: bool = True):
        return self.pending if enable and initialized else None

    def tick(self, framebuffer: Sequence[int], *, enable: bool = True,
             initialized: bool = True, pixel_ready: bool = True,
             rst_n: bool = True) -> Step:
        if len(framebuffer) != self.width * self.height:
            raise ValueError('incorrect framebuffer length')
        beat = self.peek(enable=enable and rst_n, initialized=initialized)
        accepted = bool(beat is not None and pixel_ready)
        done = bool(accepted and beat.eof)
        if not rst_n or not enable or not initialized:
            self.reset()
        elif self.pending is None or pixel_ready:
            x, y = self.fetch_x, self.fetch_y
            color = framebuffer[y * self.width + x]
            if not isinstance(color, int) or not 0 <= color <= 0xffffff:
                raise ValueError('invalid RGB888 framebuffer word')
            self.pending = Beat(x, y, color, x == 0 and y == 0,
                                x == self.width - 1,
                                x == self.width - 1 and y == self.height - 1)
            self.fetch_x += 1
            if self.fetch_x == self.width:
                self.fetch_x = 0
                self.fetch_y = (self.fetch_y + 1) % self.height
            self.frame_done = done
        else:
            self.frame_done = done
        return Step(beat, accepted, done)
