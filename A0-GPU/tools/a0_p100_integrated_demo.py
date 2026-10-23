#!/usr/bin/env python3
"""P100 DETERMINISTIC SOFTWARE-ONLY graphics/compute/host example.

Outputs a binary PPM, software CRC, trace, and independently checkable report.
Does not run SystemVerilog or access real GPU hardware.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_nextgen_graphics_p56_p80 import Framebuffer, Vertex, GraphicsState, Texture, Shader, Rect
from a0_nextgen_compute_p81_p85 import Kernel
from a0_nextgen_runtime_p86_p95 import (Buffer,ResourceTable,SoftwareQueue,CommandBuffer,Command,pack_trace,unpack_trace)


def run(directory:Path):
    fb=Framebuffer(16,16)
    tex=Texture(2,2,((1.,0.,0.,1.),(0.,1.,0.,1.),(0.,0.,1.,1.),(1.,1.,0.,1.)))
    shader=Shader((('TEX','r0','uv','zero'),('MUL','r1','r0','color')))
    verts=(Vertex(1,1,.35,(1,1,1,1),(0,0)),
           Vertex(15,1,.35,(1,1,1,1),(1,0)),
           Vertex(1,15,.35,(1,1,1,1),(0,1)))
    rt=ResourceTable(capacity=4)
    image=rt.allocate(fb)
    compute=rt.allocate(Buffer(struct.pack('<16i',*range(16))))
    q=SoftwareQueue(rt)
    commands=CommandBuffer()
    for cmd in (
        Command('CLEAR',image,(0.,0.,0.,1.)),
        Command('BARRIER'),
        Command('DRAW',image,(verts,GraphicsState(scissor=Rect(1,1,14,14),shader=shader,texture=tex))),
        Command('BARRIER'),
        Command('PRESENT',image),
        Command('DISPATCH',compute,(Kernel((('LOAD',3,0,0),('ADD',4,3,3),('STORE',0,0,4))),2,None)),
        Command('BARRIER'),
        Command('READBACK',compute)
    ):commands.append(cmd)
    commands.seal()
    fence=q.submit(commands)
    assert q.wait(fence)
    crc,rgb=q.outputs[(fence,4)]
    doubled=struct.unpack('<16i',q.outputs[(fence,7)])
    if doubled != tuple(2*i for i in range(16)):
        raise RuntimeError('compute result mismatch')
    trace_json=json.dumps(q.logs,separators=(',',':')).encode()
    framed=pack_trace(trace_json,sequence=1)
    if unpack_trace(framed)!=(1,1,trace_json):
        raise RuntimeError('trace integrity mismatch')
    directory.mkdir(parents=True,exist_ok=True)
    ppm=b'P6\n16 16\n255\n'+rgb
    (directory/'a0_p100_software_only.ppm').write_bytes(ppm)
    (directory/'a0_p100_host_trace.bin').write_bytes(framed)
    report={'status':'SOFTWARE_DEVELOPMENT_ONLY','rtl_simulated':False,'physical_gpu':False,
       'pixel_dimensions':[16,16],'frame_crc32_bgr':f'{crc:08x}',
       'rgb_sha256':hashlib.sha256(rgb).hexdigest(),'frame_bytes':len(rgb),
       'compute_values':list(doubled),'fence':fence,'command_count':len(commands.commands),
       'packet_sha256':hashlib.sha256(framed).hexdigest()}
    (directory/'a0_p100_report.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    return report

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True)
    print(json.dumps(run(ap.parse_args().output),indent=2,sort_keys=True))
