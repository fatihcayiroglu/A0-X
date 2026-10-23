"""P40 Python behavioral contract tests. These are NOT RTL simulation."""
from pathlib import Path
import random
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_frame_scanout_p40 import Beat, ScanoutEngine
from a0_triangle_coverage_p38 import Triangle
from a0_triangle_framebuffer_p39 import FramebufferEngine


class P40ScanoutTests(unittest.TestCase):
    def test_preclear_no_pixel(self):
        s = ScanoutEngine(2,2)
        for _ in range(10):
            v = s.tick([0]*4, initialized=False)
            self.assertFalse(v.accepted)
            self.assertIsNone(s.peek(initialized=False))

    def test_exact_coordinates_rgb_and_markers(self):
        w, h = 5, 3
        colors = [0x10000*i + i for i in range(w*h)]
        s = ScanoutEngine(w,h)
        accepted, dones = [], 0
        for _ in range(2*w*h+1):
            r = s.tick(colors)
            if r.accepted:
                accepted.append(r.beat)
                dones += r.frame_done
        self.assertEqual(len(accepted), 2*w*h)
        self.assertEqual(dones, 2)
        for i, b in enumerate(accepted):
            p = i % (w*h)
            self.assertEqual((b.x,b.y,b.color), (p%w,p//w,colors[p]))
            self.assertEqual(b.sof, p==0)
            self.assertEqual(b.eol, p%w==w-1)
            self.assertEqual(b.eof, p==w*h-1)

    def test_zero_backpressure_full_frame(self):
        s = ScanoutEngine(4,3)
        n = sum(s.tick([0]*12).accepted for _ in range(13))
        self.assertEqual(n,12)

    def test_stall_holds_all_fields(self):
        s = ScanoutEngine(3,2)
        data = [0xFF00 + i for i in range(6)]
        s.tick(data)
        first = s.peek()
        data[0] = 0x010203  # Buffered word must NOT change.
        for _ in range(30):
            self.assertEqual(s.peek(),first)
            self.assertFalse(s.tick(data,pixel_ready=False).accepted)
        self.assertEqual(s.tick(data).beat, first)

    def test_backpressure_randomized_lossless(self):
        for seed in range(12):
            rng = random.Random(seed)
            w,h = 7,5
            data = list(range(w*h))
            s = ScanoutEngine(w,h)
            consumed=[]
            for _ in range(600):
                r = s.tick(data,pixel_ready=rng.random()<0.37)
                if r.accepted:
                    consumed.append(r.beat)
                    if len(consumed)==w*h*2:
                        break
            self.assertEqual(len(consumed), w*h*2)
            self.assertEqual([b.color for b in consumed],data*2)
            self.assertEqual(sum(b.sof for b in consumed),2)
            self.assertEqual(sum(b.eof for b in consumed),2)

    def test_disable_drops_partial_frame_and_resumes_origin(self):
        s=ScanoutEngine(4,4)
        for _ in range(8): s.tick(list(range(16)))
        self.assertNotEqual(s.peek().x,0)
        self.assertFalse(s.tick(list(range(16)),enable=False).accepted)
        self.assertIsNone(s.peek())
        s.tick(list(range(16)))
        self.assertEqual(s.peek().x,0)
        self.assertEqual(s.peek().y,0)
        self.assertTrue(s.peek().sof)

    def test_uninitialize_aborts_and_requires_reenable(self):
        s=ScanoutEngine(4,4)
        data=list(range(16))
        for _ in range(10): s.tick(data)
        self.assertFalse(s.tick(data,initialized=False).accepted)
        self.assertIsNone(s.peek(initialized=False))
        s.tick(data,initialized=True)
        self.assertTrue(s.peek().sof)

    def test_reset_aborts_pending_output(self):
        s=ScanoutEngine(5,2)
        s.tick([9]*10)
        self.assertIsNotNone(s.peek())
        self.assertFalse(s.tick([9]*10,rst_n=False).accepted)
        self.assertIsNone(s.peek())
        s.tick([9]*10)
        self.assertEqual((s.peek().x,s.peek().y), (0,0))

    def test_one_pixel_frame(self):
        s=ScanoutEngine(1,1)
        s.tick([0x123456])
        beat=s.peek()
        self.assertEqual(beat,Beat(0,0,0x123456,True,True,True))
        self.assertTrue(s.tick([0x123456]).frame_done)
        self.assertTrue(s.peek().sof)

    def test_single_column_and_single_row(self):
        for w,h in ((1,9),(9,1)):
            s=ScanoutEngine(w,h)
            data=list(range(w*h))
            s.tick(data)
            out=[s.tick(data).beat for _ in range(w*h)]
            self.assertEqual([b.color for b in out],data)
            self.assertEqual(sum(b.eol for b in out),h)
            self.assertEqual(sum(b.sof for b in out),1)

    def test_reloading_uses_updated_frame_on_next_capture(self):
        s=ScanoutEngine(2,1)
        data=[1,2]
        s.tick(data)
        data[:]=[3,4]
        self.assertEqual(s.tick(data).beat.color,1)  # already buffered
        self.assertEqual(s.tick(data).beat.color,4)  # captured new second
        self.assertEqual(s.tick(data).beat.color,3)  # next frame start

    def test_frame_done_only_with_last_handshake(self):
        s=ScanoutEngine(2,1)
        data=[1,2]
        s.tick(data)
        s.tick(data)
        for _ in range(15):
            self.assertFalse(s.tick(data,pixel_ready=False).frame_done)
        self.assertTrue(s.tick(data,pixel_ready=True).frame_done)
        self.assertFalse(s.tick(data,pixel_ready=False).frame_done)

    def test_integration_with_p39_triangle(self):
        m=FramebufferEngine(5,4)
        m.clear(0x102030)
        m.draw(Triangle((0,0),(4,0),(0,4)),0xFFA020)
        s=ScanoutEngine(5,4)
        s.tick(m.fb)
        beats=[s.tick(m.fb).beat for _ in range(20)]
        self.assertEqual([b.color for b in beats],m.fb)
        self.assertEqual((beats[-1].x,beats[-1].y),(4,3))
        self.assertTrue(beats[-1].eof)

    def test_invalid_parameters(self):
        for dims in ((0,1),(1,0),(32768,1),(256,257)):
            with self.assertRaises(ValueError): ScanoutEngine(*dims)
        with self.assertRaises(ValueError): ScanoutEngine(2,2).tick([0])
        with self.assertRaises(ValueError): ScanoutEngine(1,1).tick([-1])
        with self.assertRaises(ValueError): ScanoutEngine(1,1).tick([0x1000000])

    def test_scanout_random_dimensions(self):
        rng=random.Random(1904)
        for _ in range(30):
            w,h=rng.randrange(1,12),rng.randrange(1,12)
            data=[rng.randrange(1<<24) for _ in range(w*h)]
            s=ScanoutEngine(w,h)
            s.tick(data)
            out=[s.tick(data).beat for _ in range(w*h)]
            self.assertEqual([b.color for b in out],data)


if __name__=='__main__':
    unittest.main(verbosity=2)
