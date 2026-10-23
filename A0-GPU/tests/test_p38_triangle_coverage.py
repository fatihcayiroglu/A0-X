"""Self-contained functional checks; these do NOT run RTL without an HDL tool."""
import random
import sys
import unittest
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_triangle_coverage_p38 import Triangle, CoverageEngine, rasterize, covers_pixel


def independent_reference(tri: Triangle, width: int, height: int):
    """Separate exact-rational half-plane oracle, without edge2()."""
    a, b, c = tri.a, tri.b, tri.c
    area = (b[0]-a[0])*(c[1]-a[1])-(c[0]-a[0])*(b[1]-a[1])
    if area == 0:
        return []
    if area < 0:
        b, c = c, b
    result = []
    for y in range(height):
        for x in range(width):
            p = (Fraction(2*x+1, 2), Fraction(2*y+1, 2))
            valid = True
            for q, r in ((a, b), (b, c), (c, a)):
                cross = ((r[0]-q[0])*(p[1]-q[1]) -
                         (r[1]-q[1])*(p[0]-q[0]))
                inclusive = r[1] < q[1] or (r[1] == q[1] and r[0] > q[0])
                if cross < 0 or (cross == 0 and not inclusive):
                    valid = False
                    break
            if valid:
                result.append((x, y))
    return result


class RasterizerTests(unittest.TestCase):
    def test_right_triangle_known_gold(self):
        tri = Triangle((1, 1), (5, 1), (1, 5))
        self.assertEqual(rasterize(tri, 8, 8),
                         [(1, 1), (2, 1), (3, 1), (1, 2), (2, 2), (1, 3)])

    def test_reverse_winding_equivalence(self):
        a, b, c = (1, 1), (5, 1), (1, 5)
        self.assertEqual(rasterize(Triangle(a, b, c), 8, 8),
                         rasterize(Triangle(a, c, b), 8, 8))

    def test_clipping_and_full_frame(self):
        self.assertEqual(len(rasterize(Triangle((-10, -10), (30, -10),
                                                (-10, 30)), 8, 8)), 64)
        self.assertEqual(rasterize(Triangle((-20,-20), (-15,-20),
                                            (-20,-15)), 8, 8), [])

    def test_degenerate_and_invalid_inputs(self):
        self.assertEqual(rasterize(Triangle((0, 0), (2, 2), (4, 4)), 8, 8), [])
        with self.assertRaises(ValueError):
            rasterize(Triangle((32768, 0), (0, 0), (0, 1)), 8, 8)
        with self.assertRaises(ValueError):
            rasterize(Triangle((0, 0), (0, 1), (1, 0)), 0, 8)

    def test_edge_sharing_has_no_double_coverage(self):
        # Square tiled by two triangles, diagonal is a shared boundary.
        a = Triangle((0,0), (4,0), (0,4))
        b = Triangle((4,0), (4,4), (0,4))
        sa, sb = set(rasterize(a, 4, 4)), set(rasterize(b, 4, 4))
        self.assertEqual(sa & sb, set())
        self.assertEqual(sa | sb, {(x, y) for y in range(4) for x in range(4)})

    def test_independent_random_reference(self):
        rng = random.Random(0xA038)
        for _ in range(300):
            tri = Triangle(*((rng.randrange(-6, 12), rng.randrange(-6, 12))
                            for _ in range(3)))
            self.assertEqual(rasterize(tri, 8, 8),
                             independent_reference(tri, 8, 8))

    def test_handshake_stall_and_order(self):
        t = Triangle((1,1), (5,1), (1,5))
        eng = CoverageEngine(8, 8)
        self.assertTrue(eng.tri_ready)
        self.assertEqual(eng.tick(tri=t), (None, False))
        self.assertFalse(eng.tri_ready)
        output = []
        pulse_count = 0
        for i in range(250):
            prior_valid, prior_pos = eng.pixel_valid, eng.pixel
            accepted, done = eng.tick(pixel_ready=(i % 5 != 0))
            if prior_valid and i % 5 == 0:
                self.assertIsNone(accepted)
                self.assertEqual(eng.pixel, prior_pos)
                self.assertTrue(eng.pixel_valid)
            if accepted is not None:
                output.append(accepted)
            if done:
                pulse_count += 1
                break
        self.assertEqual(output, rasterize(t, 8, 8))
        self.assertEqual(pulse_count, 1)
        self.assertTrue(eng.tri_ready)

    def test_reset_cancels_inflight_triangle(self):
        eng = CoverageEngine(8,8)
        eng.tick(tri=Triangle((1,1),(5,1),(1,5)))
        for _ in range(9):
            eng.tick()
        self.assertFalse(eng.tri_ready)
        self.assertEqual(eng.tick(rst_n=False), (None, False))
        self.assertTrue(eng.tri_ready)
        self.assertFalse(eng.pixel_valid)

    def test_degenerate_done_and_rearm(self):
        eng = CoverageEngine(8,8)
        self.assertEqual(eng.tick(tri=Triangle((1,1),(2,2),(3,3))),
                         (None, True))
        self.assertTrue(eng.tri_ready)
        self.assertEqual(eng.tick(tri=Triangle((1,1),(5,1),(1,5))),
                         (None, False))
        self.assertFalse(eng.tri_ready)

    def test_signed_coordinate_boundaries(self):
        tri = Triangle((-32768, -32768), (32767, -32768),
                       (-32768, 32767))
        self.assertEqual(rasterize(tri, 4, 4),
                         independent_reference(tri, 4, 4))


if __name__ == '__main__':
    unittest.main()
