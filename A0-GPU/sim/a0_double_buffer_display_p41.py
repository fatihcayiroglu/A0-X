"""P41 executable Python *reference*, NOT verification of the SystemVerilog.

The model follows the intended synchronous swap, P39 bank ownership and P40
registered scanout timing. It is used to test protocol behavior independently
before comparing against a real HDL simulator.
"""
from dataclasses import dataclass
from a0_triangle_coverage_p38 import Triangle
from a0_triangle_framebuffer_p39 import FramebufferEngine
from a0_frame_scanout_p40 import Beat, ScanoutEngine


@dataclass(frozen=True)
class DisplayStep:
    beat: Beat | None
    accepted: bool
    frame_done: bool  # Newly generated P40 frame_done on this clock
    swap_ready: bool  # Handshake readiness *before* this clock
    swap_accepted: bool
    swap_done: bool    # Registered P41 output *after* this clock
    display_bank: int
    render_bank: int
    swap_pending: bool
    clear_done: bool
    tri_done: bool


class DoubleBufferedDisplay:
    def __init__(self, width: int, height: int):
        self.banks = [FramebufferEngine(width, height) for _ in range(2)]
        self.scan = ScanoutEngine(width, height)
        self.reset()

    def reset(self):
        for bank in self.banks:
            bank.reset()
        self.scan.reset()
        self.front = 0
        self.pending = False
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
        return self.banks[self.back].busy

    def tick(self, *, scan_enable: bool = True, pixel_ready: bool = True,
             swap_valid: bool = False, clear_color: int | None = None,
             tri: Triangle | None = None, tri_color: int = 0,
             rst_n: bool = True) -> DisplayStep:
        if not rst_n:
            self.reset()
            return DisplayStep(None, False, False, False, False, False,
                               self.front, self.back, False, False, False)

        current_front = self.front
        current_back = self.back
        swap_ready = (not self.pending and self.render_initialized and
                      not self.render_busy and clear_color is None and tri is None)
        accepted_swap = swap_valid and swap_ready
        commit = self.pending and (not scan_enable or
                                   not self.display_initialized or self.scan.frame_done)
        # Disable combinationally on swap_commit; any prefetched next-frame
        # beat is suppressed before the switching edge, matching intended RTL.
        scan_step = self.scan.tick(
            [v if v is not None else 0 for v in self.banks[current_front].fb],
            enable=scan_enable and not commit,
            initialized=self.banks[current_front].initialized,
            pixel_ready=pixel_ready,
        )
        # Pending swaps freeze *new* writes; continuing clocks let a bank
        # drain any already-running operation (although swap requires idle).
        render = self.banks[current_back]
        render_can_accept = not self.pending
        clear_fire = (render_can_accept and clear_color is not None and
                      render.clear_ready)
        tri_fire = (render_can_accept and not clear_fire and
                    clear_color is None and tri is not None and render.tri_ready)
        results = []
        for idx, bank in enumerate(self.banks):
            if idx == current_back:
                results.append(bank.tick(
                    clear_color=clear_color if clear_fire else None,
                    tri=tri if tri_fire else None, tri_color=tri_color))
            else:
                results.append(bank.tick())
        self.swap_done = bool(commit)
        if commit:
            self.front = current_back
            self.pending = False
        elif accepted_swap:
            self.pending = True
        return DisplayStep(scan_step.beat, scan_step.accepted, scan_step.frame_done,
                           swap_ready, accepted_swap, self.swap_done,
                           self.front, self.back, self.pending,
                           results[current_back].clear_done,
                           results[current_back].tri_done)

    def clear_back(self, color: int):
        if self.pending:
            raise RuntimeError('render bank frozen by pending swap')
        if not self.banks[self.back].clear_ready:
            raise RuntimeError('render bank not ready to clear')
        self.tick(scan_enable=False, clear_color=color)
        for _ in range(len(self.banks[self.back].fb) + 1):
            if self.tick(scan_enable=False).clear_done:
                return
        raise RuntimeError('clear timed out')

    def draw_back(self, tri: Triangle, color: int):
        if self.pending:
            raise RuntimeError('render bank frozen by pending swap')
        if not self.banks[self.back].tri_ready:
            raise RuntimeError('render bank not ready to rasterize')
        first = self.tick(scan_enable=False, tri=tri, tri_color=color)
        if first.tri_done:
            return
        for _ in range(len(self.banks[self.back].fb) * 3 + 20):
            if self.tick(scan_enable=False).tri_done:
                return
        raise RuntimeError('triangle timed out')

    def request_swap(self, *, scan_enable: bool = True, pixel_ready: bool = False):
        first = self.tick(scan_enable=scan_enable, pixel_ready=pixel_ready, swap_valid=True)
        if not first.swap_accepted:
            raise RuntimeError('swap not ready')
        return first
