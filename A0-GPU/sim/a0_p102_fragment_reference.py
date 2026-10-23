"""Software reference contract for the P102 experimental triangle/pixel backend.

Integer RGB888/depth24, integer alpha blend, pixel-center top-left coverage.
This validates an independent software contract, *not* SystemVerilog behavior.
"""
from __future__ import annotations

from dataclasses import dataclass


def _edge(a, b, px2: int, py2: int) -> int:
    return (b[0] - a[0]) * (py2 - 2*a[1]) - (b[1] - a[1]) * (px2 - 2*a[0])


def _top_left(a, b) -> bool:
    return b[1] < a[1] or (b[1] == a[1] and b[0] > a[0])


def covered(vertices, x: int, y: int) -> bool:
    """P38 raster contract without importing P38 or P55 implementation."""
    a, b, c = vertices
    area = _edge(a, b, 2*c[0], 2*c[1])
    if area == 0:
        return False
    if area < 0:
        b, c = c, b
    edges = ((a,b), (b,c), (c,a))
    for s,t in edges:
        e = _edge(s,t,2*x+1,2*y+1)
        if e < 0 or (e == 0 and not _top_left(s,t)):
            return False
    return True


def blend_rgb(source: int, dest: int, alpha: int) -> int:
    if not 0 <= alpha <= 255:
        raise ValueError("alpha byte out of bounds")
    rgb = 0
    for shift in (16,8,0):
        s = (source >> shift) & 255
        d = (dest >> shift) & 255
        rgb |= ((s*alpha + d*(255-alpha) + 127)//255) << shift
    return rgb


@dataclass(frozen=True)
class FragmentState:
    depth_op: int = 1     # 0 ALWAYS; 1 LESS; 2 LESS_EQUAL; 3 NEVER
    depth_write: bool = True
    blend: bool = False
    alpha: int = 255
    scissor: tuple[int,int,int,int] | None = None


class PixelTarget:
    def __init__(self, width: int, height: int):
        if not (isinstance(width,int) and isinstance(height,int) and 1 <= width <= 32767
                and 1 <= height <= 32767 and width*height <= 65536):
            raise ValueError("invalid framebuffer geometry")
        self.width, self.height = width,height
        self.initialized = False
        self.colors = [None] * (width*height)
        self.depths = [None] * (width*height)

    def reset(self):
        self.initialized = False
        self.colors = [None] * (self.width*self.height)
        self.depths = [None] * (self.width*self.height)

    def clear(self, color: int, depth: int = 0xffffff):
        if not 0 <= color <= 0xffffff or not 0 <= depth <= 0xffffff:
            raise ValueError("bad clear value")
        self.colors[:] = [color]*len(self.colors)
        self.depths[:] = [depth]*len(self.depths)
        self.initialized = True

    def pixel(self, x:int, y:int):
        if not self.initialized:
            raise RuntimeError("clear required")
        if not 0 <= x < self.width or not 0 <= y < self.height:
            raise ValueError("pixel bounds")
        i=y*self.width+x
        return self.colors[i], self.depths[i]

    def draw_triangle(self, vertices, color:int, depth:int, state:FragmentState=FragmentState()):
        if not self.initialized:
            raise RuntimeError("clear required")
        if len(vertices)!=3 or not all(len(p)==2 and all(isinstance(v,int) and -32768<=v<=32767 for v in p) for p in vertices):
            raise ValueError("triangle coordinates outside signed16")
        if not (0 <= color <= 0xffffff and 0 <= depth <= 0xffffff):
            raise ValueError("pixel format")
        if not 0 <= state.alpha <= 255 or state.depth_op not in (0,1,2,3):
            raise ValueError("fragment state")
        if state.scissor is not None and (len(state.scissor)!=4 or
                any(type(v) is not int or not 0<=v<=65535 for v in state.scissor)):
            raise ValueError("invalid scissor")
        writes=0
        for y in range(self.height):
            for x in range(self.width):
                if not covered(vertices,x,y):
                    continue
                if state.scissor is not None:
                    sx,sy,sw,sh=state.scissor
                    if sw==0 or sh==0 or not(sx<=x<sx+sw and sy<=y<sy+sh):
                        continue
                index=y*self.width+x
                old_depth=self.depths[index]
                pass_depth=(state.depth_op==0 or
                            state.depth_op==1 and depth<old_depth or
                            state.depth_op==2 and depth<=old_depth)
                if not pass_depth: continue
                self.colors[index]=blend_rgb(color,self.colors[index],state.alpha) if state.blend else color
                if state.depth_write: self.depths[index]=depth
                writes+=1
        return writes
