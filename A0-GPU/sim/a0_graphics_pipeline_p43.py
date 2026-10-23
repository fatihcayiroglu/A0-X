"""P43 software-only demo harness connecting P43 and P42 REFERENCE models.

This is independent from the RTL DUT and does not prove SystemVerilog correctness.
"""
from a0_graphics_command_p43 import GraphicsFrontend
from a0_sync_display_p42 import SyncDisplay
from a0_triangle_coverage_p38 import Triangle

class P43SoftwareAdapter:
    """Orchestrates two Python *reference* models, never claims HDL parity."""
    def __init__(self,w,h):
        self.frontend=GraphicsFrontend()
        self.display=SyncDisplay(w,h)
        self.previous_done=(False,False,False)

    def step(self,command=None,*,scan_enable=False,pixel_ready=True,completion_ready=True):
        p=self.frontend.outputs(); d=self.display
        cr=(not d.pending and d.raster.tri_ready and d.banks[d.back].clear_ready)
        tr=(not d.pending and d.render_initialized and not d.render_busy)
        sw=(not d.pending and d.render_initialized and not d.render_busy)
        # No multiple command types from the frontend in one cycle.
        s=d.tick(scan_enable=scan_enable,pixel_ready=pixel_ready,
                 clear_color=p.command.color if (p.clear_valid and cr) else None,
                 tri=Triangle((p.command.vertices[0],p.command.vertices[1]),
                              (p.command.vertices[2],p.command.vertices[3]),
                              (p.command.vertices[4],p.command.vertices[5])) if (p.tri_valid and tr) else None,
                 tri_color=p.command.color if p.command else 0,
                 swap_valid=p.swap_valid and sw)
        self.frontend.tick(command=command,completion_ready=completion_ready,
                           render_initialized=d.render_initialized,
                           clear_ready=cr,tri_ready=tr,swap_ready=sw,
                           clear_done=self.previous_done[0],tri_done=self.previous_done[1],
                           swap_done=self.previous_done[2])
        self.previous_done=(s.clear_done,s.tri_done,s.swap_done)
        return p,s

    def do(self,command,*,scan_enable=False,ready=lambda t:True):
        completions=[]
        for t in range(10000):
            p,_=self.step(command if t==0 else None,scan_enable=scan_enable,
                          pixel_ready=ready(t))
            if p.completion_valid:completions.append((p.completion_tag,p.completion_error))
            if completions:return completions[0]
        raise TimeoutError('model command did not retire')

