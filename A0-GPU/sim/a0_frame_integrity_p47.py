"""P47 standalone behavioral reference (not RTL simulation).

Samples one clock edge with P42's ready/valid/sideband contract; CRC32 over
accepted B,G,R bytes only. Diagnostics are NOT delivered over P44 host wire.
"""
from dataclasses import dataclass
import zlib


@dataclass(frozen=True)
class Beat:
    x: int
    y: int
    rgb: int
    sof: bool
    eol: bool
    eof: bool


@dataclass(frozen=True)
class Observation:
    frame_valid: bool
    frame_error: bool
    frame_crc32: int | None
    accepted: bool
    aborted: bool


class FrameIntegritySpec:
    def __init__(self, width=8, height=8):
        if not isinstance(width, int) or isinstance(width, bool) or not isinstance(height, int) or isinstance(height, bool):
            raise ValueError('dimensions must be integers')
        if not (1 <= width <= 32767 and 1 <= height <= 32767 and width * height <= 65536):
            raise ValueError('unsupported P42 geometry')
        self.width, self.height = width, height
        self.reset()

    def reset(self):
        self.in_frame = False
        self.pixel_index = 0
        self.bad = False
        self._crc = 0
        self.good_frames = 0
        self.bad_frames = 0
        self.aborted_frames = 0

    def tick(self, *, stream_active=True, pixel_valid=False, pixel_ready=False,
             beat: Beat | None = None, rst_n=True) -> Observation:
        if not rst_n:
            self.reset()
            return Observation(False, False, None, False, False)
        if not stream_active:
            aborted = self.in_frame
            if aborted:
                self.aborted_frames = min(self.aborted_frames + 1, 0xffffffff)
            self.in_frame = False
            self.pixel_index = 0
            self._crc = 0
            self.bad = False
            return Observation(False, False, None, False, aborted)
        if not (pixel_valid and pixel_ready):
            return Observation(False, False, None, False, False)
        if beat is None:
            raise ValueError('accepted pixel needs beat')
        index = self.pixel_index if self.in_frame else 0
        ex, ey = index % self.width, index // self.width
        last = index == self.width * self.height - 1
        bad_beat = (beat.x != ex or beat.y != ey or
                    beat.sof != (index == 0) or
                    beat.eol != (ex == self.width - 1) or
                    beat.eof != last)
        previous_bad = self.bad if self.in_frame else False
        crc = self._crc if self.in_frame else 0
        if not isinstance(beat.rgb, int) or not 0 <= beat.rgb <= 0xffffff:
            raise ValueError('RGB must be 24-bit int')
        crc = zlib.crc32(beat.rgb.to_bytes(3, 'little'), crc)
        if beat.eof or last:
            bad = bad_beat or previous_bad
            if bad:
                self.bad_frames = min(self.bad_frames + 1, 0xffffffff)
            else:
                self.good_frames = min(self.good_frames + 1, 0xffffffff)
            self.in_frame = False
            self.pixel_index = 0
            self._crc = 0
            self.bad = False
            return Observation(True, bad, crc, True, False)
        self.in_frame = True
        self.pixel_index = index + 1
        self.bad = bad_beat or previous_bad
        self._crc = crc
        return Observation(False, False, None, True, False)


def frame_beats(width: int, height: int, colors) -> list[Beat]:
    colors = list(colors)
    if len(colors) != width * height:
        raise ValueError('frame pixel count mismatch')
    return [Beat(i % width, i // width, color,
                 i == 0, i % width == width - 1, i == width * height - 1)
            for i, color in enumerate(colors)]


def expected_crc(colors) -> int:
    return zlib.crc32(b''.join(int(c).to_bytes(3, 'little') for c in colors))
