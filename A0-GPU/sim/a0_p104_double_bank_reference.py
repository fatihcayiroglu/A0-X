"""P104 independent software *behavioral* oracle for double-buffer frame ownership.

It does not implement RTL clocks, handshake latency or physical memory timing.
Tests use it to define pixel-atomic PRESENT, bank isolation and backpressure.
"""
from dataclasses import dataclass
from a0_p102_fragment_reference import PixelTarget, FragmentState

@dataclass(frozen=True)
class Pixel:
    x: int
    y: int
    color: int
    first: bool
    line_end: bool
    frame_end: bool

class P104DoubleBankReference:
    def __init__(self, width: int, height: int):
        if not (1 <= width <= 32767 and 1 <= height <= 32767 and width * height <= 65536):
            raise ValueError('unsupported framebuffer geometry')
        self.width, self.height = width, height
        self.reset()

    def reset(self):
        self.banks = [PixelTarget(self.width,self.height) for _ in range(2)]
        self.display_bank = 0
        self.pending = False
        self.active = False
        self.cursor = 0
        self.present_commits = 0
        self.completed_frames = 0

    @property
    def render_bank(self):
        return 1 - self.display_bank

    @property
    def render_initialized(self):
        return self.banks[self.render_bank].initialized

    @property
    def display_initialized(self):
        return self.banks[self.display_bank].initialized

    def clear(self, color: int, depth: int=0xffffff):
        if self.pending:
            raise RuntimeError('cannot render with a pending bank flip')
        self.banks[self.render_bank].clear(color,depth)

    def triangle(self, coords, color, depth, state: FragmentState=FragmentState()):
        if self.pending or not self.render_initialized:
            raise RuntimeError('render target not ready')
        self.banks[self.render_bank].draw_triangle(coords,color,depth,state)

    def present(self, *, scan_enable=True):
        if self.pending or not scan_enable or not self.render_initialized:
            return False
        self.pending = True
        return True

    def step(self, *, pixel_ready=True):
        """One logical step; returns (visible pixel, accepted, frame_done, swap_done)."""
        if self.pending and not self.active:
            self.display_bank = 1-self.display_bank
            self.pending = False
            self.present_commits += 1
            self.active = True
            self.cursor = 0
            return None,False,False,True
        if not self.active:
            return None,False,False,False
        x,y = self.cursor%self.width,self.cursor//self.width
        px=Pixel(x,y,self.banks[self.display_bank].pixel(x,y)[0],
                 self.cursor==0,x==self.width-1,
                 self.cursor==self.width*self.height-1)
        done=False
        if pixel_ready:
            self.cursor += 1
            if self.cursor == self.width*self.height:
                self.active=False
                self.cursor=0
                self.completed_frames+=1
                done=True
        return px,bool(pixel_ready),done,False

    def drain(self, *, ready=lambda t: True, limit=100000):
        pixels=[]
        for t in range(limit):
            pixel,accepted,done,commit=self.step(pixel_ready=ready(t))
            if pixel is not None and accepted:
                pixels.append(pixel)
            if done and not self.pending:
                return pixels
        raise TimeoutError('no completed frame')
