"""Functional checks for the P39 Python model, not an RTL simulator."""
from pathlib import Path
import sys
import random
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_triangle_coverage_p38 import Triangle, rasterize
from a0_triangle_framebuffer_p39 import FramebufferEngine


class P39Tests(unittest.TestCase):
    def test_read_requires_clear(self):
        m = FramebufferEngine(4, 4)
        self.assertFalse(m.tri_ready)
        self.assertEqual(m.read(1, 1), 0)
        with self.assertRaises(RuntimeError): m.ppm()

    def test_clear_exact_count_and_color(self):
        m = FramebufferEngine(4, 2)
        self.assertTrue(m.clear_ready)
        m.tick(clear_color=0x102030)
        self.assertTrue(m.busy)
        self.assertFalse(m.tri_ready)
        for _ in range(7): self.assertFalse(m.tick().clear_done)
        self.assertTrue(m.tick().clear_done)
        self.assertFalse(m.tick().clear_done)
        self.assertTrue(m.initialized)
        self.assertEqual(m.fb, [0x102030] * 8)

    def test_single_triangle(self):
        m = FramebufferEngine(8, 8)
        m.clear(0x000040)
        tri = Triangle((1, 1), (5, 1), (1, 5))
        m.draw(tri, 0xFF0000)
        expected = set(rasterize(tri, 8, 8))
        for y in range(8):
            for x in range(8):
                self.assertEqual(m.read(x, y), 0xFF0000 if (x, y) in expected else 0x000040)

    def test_winding_invariance(self):
        a = FramebufferEngine(8, 8)
        b = FramebufferEngine(8, 8)
        t = Triangle((1, 1), (7, 2), (-1, 7))
        for m in (a, b): m.clear(0)
        a.draw(t, 0x00FF00)
        b.draw(Triangle(t.a, t.c, t.b), 0x00FF00)
        self.assertEqual(a.fb, b.fb)

    def test_overlay_and_background(self):
        m = FramebufferEngine(8, 8)
        m.clear(0x112233)
        a = Triangle((0, 0), (6, 0), (0, 6))
        b = Triangle((2, 2), (7, 2), (7, 7))
        m.draw(a, 0xF0A030)
        m.draw(b, 0x70B0FF)
        aa, bb = set(rasterize(a, 8, 8)), set(rasterize(b, 8, 8))
        for y in range(8):
            for x in range(8):
                expected = 0x70B0FF if (x, y) in bb else 0xF0A030 if (x, y) in aa else 0x112233
                self.assertEqual(m.read(x, y), expected)

    def test_degenerate_no_change(self):
        m = FramebufferEngine(8, 8)
        m.clear(0xABCDEF)
        m.draw(Triangle((1, 1), (2, 2), (3, 3)), 0)
        self.assertEqual(m.fb, [0xABCDEF]*64)

    def test_offscreen_triangle(self):
        m = FramebufferEngine(8, 8)
        m.clear(0x121212)
        m.draw(Triangle((-100, -100), (-80, -100), (-90, -80)), 0xFFFFFF)
        self.assertEqual(m.fb, [0x121212]*64)

    def test_reset_aborts_partial_clear(self):
        m = FramebufferEngine(8, 8)
        m.clear(0x123456)
        m.tick(clear_color=0x789ABC)
        for _ in range(5): m.tick()
        m.tick(rst_n=False)
        self.assertFalse(m.initialized)
        self.assertEqual(m.read(0, 0), 0)
        m.clear(0)
        self.assertEqual(m.fb, [0]*64)

    def test_clear_requested_during_draw_is_not_accepted(self):
        m = FramebufferEngine(8, 8)
        m.clear(0)
        m.tick(tri=Triangle((1, 1), (6, 1), (1, 6)), tri_color=0xFF)
        self.assertFalse(m.clear_ready)
        m.tick(clear_color=0xABCDEF)
        while m.busy: m.tick()
        self.assertNotIn(0xABCDEF, m.fb)

    def test_simultaneous_commands_clear_priority(self):
        m = FramebufferEngine(8, 8)
        m.clear(0)
        m.tick(clear_color=0x224466, tri=Triangle((0, 0), (5, 0), (0, 5)), tri_color=0xFFFFFF)
        self.assertFalse(m.tri_ready)
        while m.busy: m.tick()
        self.assertEqual(m.fb, [0x224466]*64)

    def test_out_of_bounds_read_zero(self):
        m = FramebufferEngine(3, 3)
        m.clear(0xFEEDCA)
        for x,y in ((3,0),(0,3),(65535,0),(-1,2)):
            self.assertEqual(m.read(x,y), 0)

    def test_ppm_output(self):
        m = FramebufferEngine(2, 1)
        m.clear(0x010203)
        self.assertEqual(m.ppm(), b'P6\n2 1\n255\n' + b'\x01\x02\x03'*2)

    def test_random_geometry(self):
        rng = random.Random(17809)
        for _ in range(200):
            m = FramebufferEngine(9, 7)
            m.clear(0x122020)
            t = Triangle(*[(rng.randrange(-15, 20), rng.randrange(-15, 20)) for _ in range(3)])
            m.draw(t, 0xFFA020)
            expected = set(rasterize(t, 9, 7))
            for y in range(7):
                for x in range(9):
                    self.assertEqual(m.read(x,y), 0xFFA020 if (x,y) in expected else 0x122020)

    def test_bad_inputs(self):
        for dims in [(0,8),(8,0),(256,257)]:
            with self.assertRaises(ValueError): FramebufferEngine(*dims)
        m = FramebufferEngine(2, 2)
        with self.assertRaises(ValueError): m.clear(0x1000000)
        with self.assertRaises(ValueError): m.tick(tri_color=-1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
