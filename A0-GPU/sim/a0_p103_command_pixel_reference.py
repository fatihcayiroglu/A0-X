"""P103 *software* behavioral model for the P43 -> P102 -> P42 research seam.

It models a serialized command frontend, a single color/depth framebuffer and
one-shot PRESENT with pixel backpressure. It is NOT an HDL simulator or a proof
that the P103 SystemVerilog passes RTL timing/handshakes.
"""
from dataclasses import dataclass
from a0_graphics_command_p43 import GraphicsFrontend, Command
from a0_p102_fragment_reference import PixelTarget, FragmentState


@dataclass(frozen=True)
class Observation:
    cmd_ready: bool
    busy: bool
    completion_valid: bool
    completion_tag: int
    completion_error: bool
    pixel_valid: bool
    pixel_x: int
    pixel_y: int
    pixel_color: int
    start_of_frame: bool
    end_of_line: bool
    end_of_frame: bool
    frame_done: bool
    present_active: bool
    initialized: bool


class P103CommandPixelModel:
    """Clocked reference intent, not cycle-exact RTL comparison."""
    def __init__(self, width: int, height: int, tag_bits: int=16):
        self.width, self.height = width, height
        self.framebuffer = PixelTarget(width, height)
        self.frontend = GraphicsFrontend(tag_bits)
        self.reset()

    def reset(self):
        self.frontend.reset()
        self.framebuffer.reset()
        self.pending = None
        self.pending_latency = 0
        self.depth_on_clear = 0xffffff
        self.fragment_state = FragmentState()
        self.depth_on_tri = 0
        self.present = False
        self.pixel_cursor = 0
        self.previous_done = (False, False, False)
        self._frame_done = False

    def step(self, command: Command | None = None, *, fragment_state: FragmentState=FragmentState(),
             depth: int=0xffffff, scan_enable: bool=True, pixel_ready: bool=True,
             completion_ready: bool=True, rst_n: bool=True) -> Observation:
        if not rst_n:
            self.reset()
            return Observation(False,False,False,0,False,False,0,0,0,
                               False,False,False,False,False,False)
        p = self.frontend.outputs()
        initialized = self.framebuffer.initialized
        active = self.pending is not None or self.present
        cr = not active
        tr = initialized and not active
        sw = initialized and not active and scan_enable
        valid = self.present
        x = self.pixel_cursor % self.width if valid else 0
        y = self.pixel_cursor // self.width if valid else 0
        color = self.framebuffer.pixel(x,y)[0] if valid else 0
        first = valid and self.pixel_cursor == 0
        last_line = valid and x == self.width-1
        last_frame = last_line and y == self.height-1
        result = Observation(
            p.cmd_ready, p.busy, p.completion_valid,p.completion_tag,
            p.completion_error,valid,x,y,color,first,last_line,last_frame,
            self._frame_done,self.present,initialized
        )
        if command is not None and p.cmd_ready:
            # Snapshot configuration on accepted input command, before OFFER.
            self.fragment_state = fragment_state
            self.depth_on_tri = depth
            self.depth_on_clear = depth
        clear_start = p.clear_valid and cr
        tri_start = p.tri_valid and tr
        present_start = p.swap_valid and sw
        previous = self.previous_done
        self.frontend.tick(command=command,completion_ready=completion_ready,
                           render_initialized=initialized,clear_ready=cr,tri_ready=tr,
                           swap_ready=sw,clear_done=previous[0],tri_done=previous[1],
                           swap_done=previous[2])
        self.previous_done = (False,False,False)
        self._frame_done = False
        if clear_start:
            self.pending = ('clear',p.command)
            self.pending_latency = self.width*self.height + 1
        elif tri_start:
            self.pending = ('triangle',p.command,self.depth_on_tri,self.fragment_state)
            self.pending_latency = self.width*self.height + 1
        elif present_start:
            self.present = True
            self.pixel_cursor = 0
        elif self.pending is not None:
            self.pending_latency -= 1
            if self.pending_latency == 0:
                kind,*other = self.pending
                if kind == 'clear':
                    self.framebuffer.clear(other[0].color,self.depth_on_clear)
                    self.previous_done = (True,False,False)
                else:
                    cmd,dep,state=other
                    v=cmd.vertices
                    self.framebuffer.draw_triangle(((v[0],v[1]),(v[2],v[3]),(v[4],v[5])),
                                                   cmd.color,dep,state)
                    self.previous_done = (False,True,False)
                self.pending = None
        if result.pixel_valid and pixel_ready:
            self.pixel_cursor += 1
            if self.pixel_cursor == self.width*self.height:
                self.present=False
                self.pixel_cursor=0
                self._frame_done=True
                self.previous_done=(False,False,True)
        return result

    def run_command(self, command: Command, *, state: FragmentState=FragmentState(),
                    depth: int=0xffffff, scan_enable=True, ready=lambda cycle: True,
                    max_cycles=30000):
        """Reference driver: honors input/output handshakes and collects pixel beats."""
        accepted = False
        pixels=[]
        completions=[]
        for t in range(max_cycles):
            r=self.step(command if not accepted else None,fragment_state=state,
                        depth=depth,scan_enable=scan_enable,pixel_ready=ready(t))
            if not accepted and r.cmd_ready:
                accepted=True
            if r.pixel_valid and ready(t):
                pixels.append((r.pixel_x,r.pixel_y,r.pixel_color,
                               r.start_of_frame,r.end_of_line,r.end_of_frame))
            if r.completion_valid:
                completions.append((r.completion_tag,r.completion_error))
                self.step(completion_ready=True)
                return completions[0],pixels
        raise TimeoutError('P103 reference command did not complete')
