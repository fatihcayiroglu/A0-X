"""Produce a PPM frame with the A0-X P39 Python reference model.

A diagnostic software-model render, NOT a GPU-executed or FPGA output.
Run: python A0-GPU/tools/p39_demo.py /path/to/output.ppm
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_triangle_coverage_p38 import Triangle
from a0_triangle_framebuffer_p39 import FramebufferEngine


def main():
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('p39-software-reference.ppm')
    m = FramebufferEngine(128, 128)
    m.clear(0x0D172C)
    m.draw(Triangle((8, 112), (58, 8), (121, 111)), 0x00CCB2)
    m.draw(Triangle((40, 96), (80, 37), (117, 97)), 0xFFAB48)
    m.draw(Triangle((53, 78), (66, 57), (80, 78)), 0xD63E70)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(m.ppm())
    print(f'P39 PYTHON-ONLY reference image: {dest} ({dest.stat().st_size} bytes)')


if __name__ == '__main__':
    main()
