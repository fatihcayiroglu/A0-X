"""Software contract validation for P102 unverified RTL integration."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_p102_fragment_reference import PixelTarget, FragmentState, covered, blend_rgb
from a0_independent_graphics_oracle_p55 import _covered as p55_covered


class P102SoftwareContract(unittest.TestCase):
    TRI=((0,0),(4,0),(0,4))
    def setUp(self):
        self.fb=PixelTarget(4,4)
        self.fb.clear(0,0xffffff)

    def test_reset_rejects_uninitialized_memory(self):
        self.fb.reset()
        with self.assertRaises(RuntimeError): self.fb.pixel(0,0)
        with self.assertRaises(RuntimeError): self.fb.draw_triangle(self.TRI,0,0)
        self.fb.clear(0x123456,0x222222)
        self.assertEqual(self.fb.pixel(0,0),(0x123456,0x222222))

    def test_scissor_restricts_writes(self):
        count=self.fb.draw_triangle(self.TRI,0xff0000,0x400,FragmentState(scissor=(1,1,2,2)))
        self.assertEqual(count,1)
        self.assertEqual(self.fb.pixel(1,1),(0xff0000,0x400))
        self.assertEqual(self.fb.pixel(0,0),(0,0xffffff))

    def test_depth_less_and_lequal(self):
        self.fb.draw_triangle(self.TRI,0xff0000,0x400)
        self.fb.draw_triangle(self.TRI,0x00ff00,0x500)
        self.assertEqual(self.fb.pixel(1,1),(0xff0000,0x400))
        self.fb.draw_triangle(self.TRI,0xabcdef,0x400,FragmentState(depth_op=2))
        self.assertEqual(self.fb.pixel(1,1),(0xabcdef,0x400))

    def test_always_and_never_modes(self):
        self.fb.draw_triangle(self.TRI,0xff0000,10)
        count=self.fb.draw_triangle(self.TRI,0x0000ff,5,FragmentState(depth_op=3))
        self.assertEqual(count,0)
        self.fb.draw_triangle(self.TRI,0x00ff00,123,FragmentState(depth_op=0))
        self.assertEqual(self.fb.pixel(1,1),(0x00ff00,123))

    def test_blend_integer_rounding_and_limits(self):
        self.assertEqual(blend_rgb(0x00ff00,0xff0000,128),0x7f8000)
        self.assertEqual(blend_rgb(0x123456,0xabcdef,0),0xabcdef)
        self.assertEqual(blend_rgb(0x123456,0xabcdef,255),0x123456)
        self.fb.draw_triangle(self.TRI,0xff0000,0x400)
        self.fb.draw_triangle(self.TRI,0x00ff00,0x200,FragmentState(blend=True,alpha=128))
        self.assertEqual(self.fb.pixel(1,1),(0x7f8000,0x200))

    def test_depth_write_disable(self):
        self.fb.draw_triangle(self.TRI,0xff0000,0x400)
        self.fb.draw_triangle(self.TRI,0xffffff,0x200,FragmentState(depth_write=False))
        self.assertEqual(self.fb.pixel(1,1),(0xffffff,0x400))

    def test_empty_scissor_and_boundaries(self):
        for sc in ((0,0,0,1),(0,0,1,0),(20,20,1,1),(65535,65535,65535,65535)):
            self.assertEqual(self.fb.draw_triangle(self.TRI,0xffffff,1,FragmentState(scissor=sc)),0)
        self.assertEqual(self.fb.pixel(1,1),(0,0xffffff))

    def test_invalid_geometry_and_coordinates(self):
        for a,b in ((0,4),(4,0),(10000,8)):
            with self.assertRaises(ValueError):PixelTarget(a,b)
        with self.assertRaises(ValueError):self.fb.draw_triangle(((0,0),(4,0),(32768,4)),1,1)
        with self.assertRaises(ValueError):self.fb.draw_triangle(self.TRI,1,-1)
        with self.assertRaises(ValueError):self.fb.draw_triangle(self.TRI,1,1,FragmentState(scissor=(-1,0,2,2)))
        with self.assertRaises(ValueError):self.fb.pixel(4,0)

    def test_winding_is_normalized(self):
        a=self.fb.draw_triangle(self.TRI,0xff0000,5)
        colors_a=self.fb.colors[:]
        self.fb.clear(0)
        b=self.fb.draw_triangle((self.TRI[0],self.TRI[2],self.TRI[1]),0xff0000,5)
        self.assertEqual(a,b)
        self.assertEqual(colors_a,self.fb.colors)

    def test_randomized_coverage_against_p55_independent_oracle(self):
        rng=random.Random(102)
        for i in range(240):
            pts=tuple((rng.randint(-5,10),rng.randint(-5,10)) for _ in range(3))
            for y in range(4):
                for x in range(4):
                    self.assertEqual(covered(pts,x,y),p55_covered(*pts,x,y),(pts,x,y))

    def test_randomized_fragment_compositing_invariants(self):
        rng=random.Random(200)
        for _ in range(80):
            fb=PixelTarget(4,4);fb.clear(0x345678,0xffffff)
            for __ in range(6):
                pts=tuple((rng.randint(-2,6),rng.randint(-2,6)) for _ in range(3))
                color=rng.randint(0,0xffffff);depth=rng.randint(0,0xffffff)
                state=FragmentState(depth_op=rng.randrange(4),depth_write=bool(rng.randrange(2)),
                    blend=bool(rng.randrange(2)),alpha=rng.randint(0,255),
                    scissor=(rng.randrange(4),rng.randrange(4),rng.randrange(4),rng.randrange(4)))
                before_c=fb.colors[:];before_d=fb.depths[:]
                writes=fb.draw_triangle(pts,color,depth,state)
                changed_c=sum(a!=b for a,b in zip(before_c,fb.colors))
                changed_d=sum(a!=b for a,b in zip(before_d,fb.depths))
                self.assertLessEqual(changed_c,writes)
                self.assertLessEqual(changed_d,writes)
                self.assertLessEqual(writes,16)
                if not state.depth_write:self.assertEqual(fb.depths,before_d)

    def test_rtl_integration_wires_named_candidates(self):
        # Static interface check only; NOT a behavioral HDL test.
        src=(Path(__file__).resolve().parents[1]/'rtl/graphics/a0_triangle_scissor_depth_blend_p102.sv').read_text()
        for name in ('a0_triangle_coverage_p38','a0_p59_scissor_coverage',
                     'a0_p68_depth_compare','a0_p70_rgb_blend',
                     '.candidate_valid(raster_pixel_valid && scissor_pass)',
                     'if (depth_write_q) depth_ram[raster_index] <= tri_depth_q;'):
            self.assertIn(name,src)


if __name__=='__main__':unittest.main()
