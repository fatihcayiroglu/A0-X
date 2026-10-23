"""P42 Python *reference model*, NOT validation of the SystemVerilog implementation.

Models single-edge registered read latency, one-outstanding-request scanout,
back-buffer ownership and EOF-triggered bank swap. This explicitly does not
represent FPGA timing, dual-clock CDC, DDR/HBM, or video/display PHY signals.
"""
from dataclasses import dataclass
from a0_triangle_coverage_p38 import CoverageEngine, Triangle


@dataclass(frozen=True)
class Pixel:
    x: int
    y: int
    color: int
    sof: bool
    eol: bool
    eof: bool


@dataclass(frozen=True)
class Step:
    beat: Pixel | None
    accepted: bool
    frame_done: bool
    swap_accepted: bool
    swap_done: bool
    clear_done: bool
    tri_done: bool


class SyncFrameRAM:
    def __init__(self, pixels: int):
        if not 1 <= pixels <= 65536:
            raise ValueError('P42 RAM accepts 1..65536 pixels')
        self.pixels = pixels
        self.cells = [None] * pixels
        self.reset()

    def reset(self):
        # Do not assume SRAM resets its contents.
        self.initialized = False
        self.clearing = False
        self.clear_addr = 0
        self.clear_color = 0
        self.clear_done = False
        self.read_valid = False
        self.read_data = 0

    @property
    def clear_ready(self):
        return not self.clearing

    def write_ready(self, clear_requested=False):
        return self.initialized and not self.clearing and not clear_requested

    def tick(self, *, clear_color=None, write_addr=None, write_color=0,
             read_addr=None, rst_n=True):
        if not rst_n:
            self.reset()
            return
        old_initialized = self.initialized
        # Read first from OLD memory contents, matching a registered 1R/1W RAM.
        self.read_valid = read_addr is not None and old_initialized and 0 <= read_addr < self.pixels
        if self.read_valid:
            self.read_data = self.cells[read_addr]
        self.clear_done = False
        if self.clearing:
            self.cells[self.clear_addr] = self.clear_color
            if self.clear_addr == self.pixels - 1:
                self.clearing = False
                self.clear_addr = 0
                self.initialized = True
                self.clear_done = True
            else:
                self.clear_addr += 1
        elif clear_color is not None:
            self.clearing = True
            self.clear_addr = 0
            self.clear_color = clear_color
            self.initialized = False
        elif write_addr is not None and old_initialized and 0 <= write_addr < self.pixels:
            self.cells[write_addr] = write_color

    def clear(self, color):
        assert self.clear_ready
        self.tick(clear_color=color)
        for _ in range(self.pixels):
            self.tick()
        assert self.clear_done


class SyncScanout:
    def __init__(self, width: int, height: int):
        if width < 1 or height < 1 or width > 32767 or height > 32767 or width * height > 65536:
            raise ValueError('P42 scanout dimensions unsupported')
        self.width, self.height = width, height
        self.reset()

    def reset(self):
        self.state = 'ISSUE'
        self.cursor = 0
        self.x = self.y = 0
        self.beat = None
        self.frame_done = False

    def peek(self, *, enable=True, initialized=True):
        return self.beat if enable and initialized and self.state == 'HOLD' else None

    def tick(self, ram: SyncFrameRAM, *, enable, ready=True, rst_n=True):
        if not rst_n:
            self.reset()
            ram.tick(rst_n=False)
            return None, False
        running = enable and ram.initialized
        beat = self.peek(enable=enable, initialized=ram.initialized)
        accepted = beat is not None and ready
        read_addr = self.cursor if running and self.state == 'ISSUE' else None
        old_valid, old_data = ram.read_valid, ram.read_data
        self.frame_done = bool(accepted and beat.eof)
        if not running:
            self.state = 'ISSUE'
            self.cursor = 0
            self.x = self.y = 0
            self.beat = None
        elif self.state == 'ISSUE':
            self.state = 'WAIT_READ'
        elif self.state == 'WAIT_READ' and old_valid:
            self.beat = Pixel(self.x, self.y, old_data,
                              self.x == 0 and self.y == 0,
                              self.x == self.width - 1,
                              self.x == self.width - 1 and self.y == self.height - 1)
            self.state = 'HOLD'
        elif self.state == 'HOLD' and accepted:
            self.state = 'ISSUE'
            if self.x == self.width - 1:
                self.x = 0
                if self.y == self.height - 1:
                    self.y = 0
                    self.cursor = 0
                else:
                    self.y += 1
                    self.cursor += 1
            else:
                self.x += 1
                self.cursor += 1
        ram.tick(read_addr=read_addr)
        return beat, accepted


class SyncDisplay:
    def __init__(self, width, height):
        self.scan = SyncScanout(width, height)
        self.banks = [SyncFrameRAM(width * height) for _ in range(2)]
        self.raster = CoverageEngine(width, height)
        self.width, self.height = width, height
        self.reset()

    def reset(self):
        for bank in self.banks:
            bank.reset()
        self.scan.reset()
        self.raster.reset()
        self.front = 0
        self.pending = False
        self.tri_color = 0
        self.swap_done = False

    @property
    def back(self):
        return 1 - self.front

    @property
    def display_initialized(self):
        return self.banks[self.front].initialized

    @property
    def render_initialized(self):
        return self.banks[self.back].initialized

    @property
    def render_busy(self):
        return self.banks[self.back].clearing or not self.raster.tri_ready

    def tick(self, *, scan_enable=True, pixel_ready=True, clear_color=None,
             tri=None, tri_color=0, swap_valid=False, rst_n=True):
        if not rst_n:
            self.reset()
            return Step(None, False, False, False, False, False, False)
        current_front = self.front
        current_back = self.back
        front, back = self.banks[current_front], self.banks[current_back]
        swap_ready = (not self.pending and not self.render_busy and
                      back.initialized and clear_color is None and tri is None)
        swap_accepted = swap_valid and swap_ready
        commit = self.pending and (not scan_enable or not front.initialized or self.scan.frame_done)
        beat, accepted = self.scan.tick(front, enable=scan_enable and not commit,
                                        ready=pixel_ready)
        frame_done = self.scan.frame_done
        clear_ready = not self.pending and self.raster.tri_ready and back.clear_ready
        tri_ready = (not self.pending and clear_color is None and
                     back.initialized and not back.clearing and self.raster.tri_ready)
        clear_requested = clear_color is not None and clear_ready
        tri_requested = tri is not None and tri_ready
        if tri_requested:
            self.tri_color = tri_color
        px, tri_done = self.raster.tick(tri=tri if tri_requested else None,
                                         pixel_ready=back.write_ready(clear_color is not None))
        wr_addr = px[1] * self.width + px[0] if px is not None else None
        back.tick(clear_color=clear_color if clear_requested else None,
                  write_addr=wr_addr, write_color=self.tri_color)
        clear_done = back.clear_done
        self.swap_done = bool(commit)
        if commit:
            self.front = current_back
            self.pending = False
        elif swap_accepted:
            self.pending = True
        return Step(beat, accepted, frame_done, swap_accepted, bool(commit),
                    clear_done, tri_done)

    def clear_back(self, color):
        self.tick(scan_enable=False, clear_color=color)
        for _ in range(self.width * self.height):
            s = self.tick(scan_enable=False)
        assert s.clear_done

    def draw_back(self, tri, color):
        if self.render_busy or not self.render_initialized:
            raise RuntimeError('render bank unavailable')
        s = self.tick(scan_enable=False, tri=tri, tri_color=color)
        for _ in range(self.width * self.height+1):
            if s.tri_done:
                return
            s = self.tick(scan_enable=False)
        raise RuntimeError('triangle did not complete')

    def swap_when_disabled(self):
        s = self.tick(scan_enable=False, swap_valid=True)
        assert s.swap_accepted
        s = self.tick(scan_enable=False)
        assert s.swap_done
