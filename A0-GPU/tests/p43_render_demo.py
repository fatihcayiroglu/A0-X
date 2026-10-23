"""P43 deterministic reference-only graphics image + completed command ledger.

Run: python tests/p43_render_demo.py --output /tmp/a0_p43_demo.png
No hardware/RTL performance or correctness claims are implied.
"""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, Command
from a0_graphics_pipeline_p43 import P43SoftwareAdapter


def draw(width=96,height=64):
    p=P43SoftwareAdapter(width,height)
    script=[
        Command(CLEAR,1,0x0D172D),
        Command(TRIANGLE,2,0x33CEAD,(6,8,85,14,14,57)),
        Command(TRIANGLE,3,0xEAA43B,(33,2,92,60,50,54)),
        Command(TRIANGLE,4,0xBD5AE0,(5,61,42,23,74,61)),
        Command(PRESENT,5),
    ]
    completion=[]
    for cmd in script:
        tag,error=p.do(cmd,scan_enable=False)
        if error or tag!=cmd.tag:raise RuntimeError('reference command failed')
        completion.append({'tag':tag,'opcode':cmd.opcode,'error':error})
    cells=p.display.banks[p.display.front].cells
    if len(cells)!=width*height or not p.display.display_initialized:raise RuntimeError('incomplete output')
    return cells,completion


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--output',required=True,help='PPM or PNG output (PNG requires Pillow)')
    args=ap.parse_args()
    width,height=96,64
    cells,completion=draw(width,height)
    path=Path(args.output)
    path.parent.mkdir(parents=True,exist_ok=True)
    raw=b''.join(int(c).to_bytes(3,'big') for c in cells)
    if path.suffix.lower()=='.png':
        from PIL import Image
        Image.frombytes('RGB',(width,height),raw).save(path)
    else:
        path.write_bytes(f'P6\n{width} {height}\n255\n'.encode()+raw)
    receipt=path.with_suffix('.json')
    receipt.write_text(json.dumps({'type':'SOFTWARE_REFERENCE_ONLY',
                                   'resolution':[width,height],
                                   'commands':completion},indent=2)+'\n')
    print('P43 SOFTWARE REFERENCE ONLY',path,'commands',len(completion))

if __name__=='__main__':main()
