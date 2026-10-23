"""P56-P80 experimental graphics SOFTWARE reference.

Pixel centers follow P38/P55 y-down integer-position conventions. Explicitly
not RTL, a Vulkan/DirectX driver, or a claim of hardware synthesis.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import math
import zlib


def _v4(value):
    if len(value) != 4 or not all(isinstance(x, (int, float)) and math.isfinite(x) for x in value):
        raise ValueError('expected finite RGBA vector')
    return tuple(float(x) for x in value)


def _sat(x):
    return min(1.0, max(0.0, x))


def _byte(x):
    return int(_sat(x) * 255 + 0.5)


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    def __post_init__(self):
        if any(type(v) is not int for v in (self.x,self.y,self.width,self.height)) or self.width < 0 or self.height < 0:
            raise ValueError('invalid rectangle')

    def contains(self,x,y):
        return self.x <= x < self.x+self.width and self.y <= y < self.y+self.height


@dataclass(frozen=True)
class Vertex:
    x: int
    y: int
    depth: float = 0.5
    rgba: tuple = (1.0,1.0,1.0,1.0)
    uv: tuple = (0.0,0.0)

    def __post_init__(self):
        if type(self.x) is not int or type(self.y) is not int:
            raise ValueError('vertex coordinates must be integers')
        if not isinstance(self.depth,(int,float)) or not 0 <= self.depth <= 1 or not math.isfinite(self.depth):
            raise ValueError('depth outside normalized range')
        _v4(self.rgba)
        if len(self.uv) != 2 or not all(isinstance(t,(int,float)) and math.isfinite(t) for t in self.uv):
            raise ValueError('invalid UV')


@dataclass(frozen=True)
class Texture:
    width: int
    height: int
    pixels: tuple

    def __post_init__(self):
        if type(self.width) is not int or type(self.height) is not int or not 1 <= self.width <= 4096 or not 1 <= self.height <= 4096 or self.width*self.height>262144:
            raise ValueError('texture dimensions')
        if len(self.pixels) != self.width*self.height:
            raise ValueError('texture pixel count')
        for px in self.pixels:
            _v4(px)

    def pixel(self,x,y):
        return _v4(self.pixels[y*self.width+x])


def _wrap(value, mode):
    if mode == 'repeat':
        return value % 1.0
    if mode == 'clamp':
        return max(0.0,min(1.0,value))
    raise ValueError('unknown sampler address mode')


def sample(texture: Texture, uv: tuple, *, mode='clamp', filtering='nearest'):
    if len(uv) != 2 or not all(isinstance(q,(float,int)) and math.isfinite(q) for q in uv):
        raise ValueError('invalid texture coordinates')
    u,v = (_wrap(float(q),mode) for q in uv)
    if filtering == 'nearest':
        x = min(texture.width-1,int(u*texture.width))
        y = min(texture.height-1,int(v*texture.height))
        return texture.pixel(x,y)
    if filtering != 'linear':
        raise ValueError('unknown filter')
    # Texel-centre bilinear interpolation; for repeat sample all four wrapped texels.
    fx,fy=u*texture.width-0.5,v*texture.height-0.5
    x0,y0=math.floor(fx),math.floor(fy)
    tx,ty=fx-x0,fy-y0
    def at(x,y):
        if mode == 'repeat':
            return texture.pixel(x%texture.width,y%texture.height)
        return texture.pixel(max(0,min(texture.width-1,x)),max(0,min(texture.height-1,y)))
    a,b,c,d=at(x0,y0),at(x0+1,y0),at(x0,y0+1),at(x0+1,y0+1)
    return tuple((a[i]*(1-tx)+b[i]*tx)*(1-ty)+(c[i]*(1-tx)+d[i]*tx)*ty for i in range(4))


_OPS={'MOV','ADD','MUL','MAD','MIN','MAX','SAT','TEX'}
@dataclass(frozen=True)
class Shader:
    """Bounded straight-line four-lane vector shader; no untrusted code execution."""
    instructions: tuple
    budget: int = 32

    def __post_init__(self):
        if not 1 <= len(self.instructions) <= self.budget <= 32:
            raise ValueError('shader length/budget')
        allowed={'color','uv','const0','one','zero'}
        for step in self.instructions:
            if len(step)!=4:
                raise ValueError('instruction arity')
            op,dst,src1,src2=step
            if op not in _OPS or not isinstance(dst,str) or not dst.startswith('r') or not dst[1:].isdigit() or int(dst[1:])>=8:
                raise ValueError('unknown opcode or invalid destination')
            for reg in (src1,src2):
                if reg not in allowed:
                    raise ValueError('unknown or uninitialized source register')
            allowed.add(dst)

    def evaluate(self, color, uv, *, const0=(1,1,1,1), texture=None, mode='clamp', filtering='nearest'):
        registers={'color':_v4(color),'uv':(float(uv[0]),float(uv[1]),0.0,0.0),
                   'const0':_v4(const0),'one':(1.,)*4,'zero':(0.,)*4}
        last=None
        for op,dst,s1,s2 in self.instructions:
            a,b=registers[s1],registers[s2]
            if op=='MOV': result=a
            elif op=='ADD': result=tuple(a[i]+b[i] for i in range(4))
            elif op=='MUL': result=tuple(a[i]*b[i] for i in range(4))
            elif op=='MAD': result=tuple(a[i]*b[i]+registers['const0'][i] for i in range(4))
            elif op=='MIN': result=tuple(min(a[i],b[i]) for i in range(4))
            elif op=='MAX': result=tuple(max(a[i],b[i]) for i in range(4))
            elif op=='SAT': result=tuple(_sat(x) for x in a)
            elif op=='TEX':
                if texture is None: raise ValueError('shader requires texture')
                result=sample(texture,a[:2],mode=mode,filtering=filtering)
            registers[dst]=result
            last=result
        return _v4(last)


def edge(a,b,px2,py2):
    return (b.x-a.x)*(py2-2*a.y)-(b.y-a.y)*(px2-2*a.x)


def triangle_fragments(vertices, width,height, viewport=(0,0), scissor=None, cull='none'):
    if cull not in ('none','cw','ccw'): raise ValueError('unknown culling')
    if len(vertices)!=3: raise ValueError('triangle requires three vertices')
    a,b,c=[Vertex(v.x+viewport[0],v.y+viewport[1],v.depth,v.rgba,v.uv) for v in vertices]
    orient=edge(a,b,2*c.x,2*c.y)
    if orient==0 or (cull=='cw' and orient<0) or (cull=='ccw' and orient>0):
        return
    if orient<0: b,c=c,b
    area=edge(a,b,2*c.x,2*c.y)
    x0=max(0,min(a.x,b.x,c.x)); x1=min(width-1,max(a.x,b.x,c.x))
    y0=max(0,min(a.y,b.y,c.y)); y1=min(height-1,max(a.y,b.y,c.y))
    for y in range(y0,y1+1):
        for x in range(x0,x1+1):
            if scissor is not None and not scissor.contains(x,y): continue
            px,py=2*x+1,2*y+1
            edges=[(a,b),(b,c),(c,a)]
            e=[edge(u,v,px,py) for u,v in edges]
            if any(w<0 or (w==0 and not (v.y<u.y or (v.y==u.y and v.x>u.x))) for w,(u,v) in zip(e,edges)):
                continue
            weights=(edge(b,c,px,py)/area,edge(c,a,px,py)/area,edge(a,b,px,py)/area)
            z=sum(t*v.depth for t,v in zip(weights,(a,b,c)))
            rgba=tuple(sum(t*v.rgba[i] for t,v in zip(weights,(a,b,c))) for i in range(4))
            uv=tuple(sum(t*v.uv[i] for t,v in zip(weights,(a,b,c))) for i in range(2))
            yield x,y,z,rgba,uv


@dataclass
class GraphicsState:
    scissor: Rect | None = None
    viewport: tuple = (0,0)
    cull: str = 'none'
    depth_compare: str = 'less'
    depth_write: bool = True
    blending: bool = False
    shader: Shader | None = None
    texture: Texture | None = None
    sampler_address: str = 'clamp'
    sampler_filter: str = 'nearest'
    uniform: tuple = (1.,1.,1.,1.)


class Framebuffer:
    def __init__(self,width,height):
        if type(width) is not int or type(height) is not int or width<1 or height<1 or width*height>65536:
            raise ValueError('invalid framebuffer dimensions')
        self.width,self.height=width,height
        self.colors=[(0.,0.,0.,1.)]*(width*height)
        self.depths=[1.0]*(width*height)
        self.drawn=0

    def clear(self, rgba=(0.,0.,0.,1.),depth=1.0):
        if not 0<=depth<=1 or not math.isfinite(depth): raise ValueError('invalid clear depth')
        self.colors=[_v4(rgba)]*len(self.colors)
        self.depths=[float(depth)]*len(self.depths)

    def pixel(self,x,y):
        if not (0<=x<self.width and 0<=y<self.height): raise ValueError('pixel bounds')
        return tuple(_byte(q) for q in self.colors[y*self.width+x])

    def draw(self,vertices,state=None):
        state=state or GraphicsState()
        count=0
        for x,y,z,rgba,uv in triangle_fragments(vertices,self.width,self.height,state.viewport,state.scissor,state.cull):
            index=y*self.width+x
            if state.depth_compare=='less': passed=z<self.depths[index]
            elif state.depth_compare=='lequal': passed=z<=self.depths[index]
            elif state.depth_compare=='always': passed=True
            else: raise ValueError('invalid depth function')
            if not passed: continue
            if state.shader:
                rgba=state.shader.evaluate(rgba,uv,const0=state.uniform,texture=state.texture,
                              mode=state.sampler_address,filtering=state.sampler_filter)
            elif state.texture:
                sampled=sample(state.texture,uv,mode=state.sampler_address,filtering=state.sampler_filter)
                rgba=tuple(rgba[i]*sampled[i] for i in range(4))
            rgba=tuple(_sat(i) for i in rgba)
            if state.blending:
                background=self.colors[index]
                alpha=rgba[3]
                rgba=tuple(rgba[i]*alpha+background[i]*(1-alpha) for i in range(3))+(alpha+background[3]*(1-alpha),)
            self.colors[index]=rgba
            if state.depth_write: self.depths[index]=z
            count+=1
        self.drawn+=count
        return count

    def rgb_bytes(self):
        return bytes(channel for r,g,b,a in self.colors for channel in (_byte(r),_byte(g),_byte(b)))

    def crc32(self):
        # P47/P55 CRC contract consumes BGR, not RGB.
        return zlib.crc32(bytes(channel for r,g,b,a in self.colors for channel in (_byte(b),_byte(g),_byte(r))))&0xffffffff
