"""Executable reference contract: not evidence of P41 HDL correctness."""
import random
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_double_buffer_display_p41 import DoubleBufferedDisplay
from a0_triangle_coverage_p38 import Triangle


class TestP41DoubleBuffer(unittest.TestCase):
    def _ready_front(self, w=4, h=3, color=0x123456):
        d = DoubleBufferedDisplay(w, h)
        d.clear_back(color)
        s = d.request_swap(scan_enable=False)
        self.assertTrue(s.swap_accepted)
        s = d.tick(scan_enable=False)
        self.assertTrue(s.swap_done)
        self.assertEqual(d.front, 1)
        return d

    def test_reset_both_banks_uninitialized(self):
        d = DoubleBufferedDisplay(3, 2)
        self.assertEqual((d.front, d.back), (0, 1))
        self.assertFalse(d.display_initialized)
        self.assertFalse(d.render_initialized)
        self.assertFalse(d.tick(swap_valid=True).swap_accepted)
        self.assertIsNone(d.tick().beat)

    def test_first_uninitialized_front_allows_swap(self):
        d = DoubleBufferedDisplay(3, 2)
        d.clear_back(0xAABBCC)
        d.request_swap()
        self.assertTrue(d.tick().swap_done)
        self.assertTrue(d.display_initialized)
        d.tick()
        self.assertEqual(d.scan.peek().color, 0xAABBCC)

    def test_no_swap_until_clear_complete(self):
        d = DoubleBufferedDisplay(5, 4)
        d.tick(scan_enable=False, clear_color=0x123456)
        for _ in range(20):
            self.assertFalse(d.tick(scan_enable=False, swap_valid=True).swap_accepted)
        self.assertTrue(d.render_initialized)
        self.assertTrue(d.tick(scan_enable=False, swap_valid=True).swap_accepted)

    def test_midframe_swap_does_not_tear(self):
        d = self._ready_front()
        d.clear_back(0xABCDEF)
        d.tick(scan_enable=True, pixel_ready=False)  # Prefetch old front
        s = d.request_swap()
        self.assertTrue(s.swap_pending)
        old = []
        swapped = 0
        first_new = None
        for i in range(120):
            s = d.tick(pixel_ready=True)
            if s.accepted:
                if not swapped:
                    old.append(s.beat)
                elif first_new is None:
                    first_new = s.beat
            if s.swap_done:
                swapped += 1
            if swapped and first_new:
                break
        self.assertEqual(swapped, 1)
        self.assertEqual(len(old), 12)
        self.assertTrue(all(b.color == 0x123456 for b in old))
        self.assertEqual((first_new.x, first_new.y, first_new.color), (0, 0, 0xABCDEF))
        self.assertTrue(first_new.sof)

    def test_pending_blocks_render_and_duplicate_swaps(self):
        d = self._ready_front()
        d.clear_back(0xEEEEEE)
        d.tick(pixel_ready=False)
        d.request_swap()
        old = list(d.banks[d.back].fb)
        for _ in range(12):
            s = d.tick(pixel_ready=False, swap_valid=True, clear_color=0x000000)
            self.assertFalse(s.swap_ready)
            self.assertEqual(d.banks[d.back].fb, old)
            self.assertTrue(s.swap_pending)
        self.assertTrue(d.tick(scan_enable=False).swap_done)

    def test_disabled_scan_commit_aborts_stalled_pixel(self):
        d = self._ready_front()
        d.clear_back(0x654321)
        d.tick(pixel_ready=False)
        self.assertEqual(d.scan.peek().color, 0x123456)
        d.request_swap()
        done = d.tick(scan_enable=False, pixel_ready=False)
        self.assertTrue(done.swap_done)
        self.assertFalse(done.accepted)
        self.assertIsNone(d.scan.peek())
        d.tick(pixel_ready=False)
        self.assertEqual((d.scan.peek().x,d.scan.peek().y,d.scan.peek().color), (0,0,0x654321))

    def test_two_ping_pong_swaps(self):
        d = self._ready_front(color=0x010203)
        for color in (0x101112, 0x202122, 0x303132):
            front_before = d.front
            d.clear_back(color)
            d.request_swap(scan_enable=False)
            self.assertTrue(d.tick(scan_enable=False).swap_done)
            self.assertNotEqual(d.front, front_before)
            self.assertEqual(d.banks[d.front].fb, [color] * 12)

    def test_random_stalls_preserve_frame(self):
        for seed in range(12):
            rng = random.Random(seed)
            d = self._ready_front(w=7,h=5)
            d.clear_back(0x998877)
            d.tick(pixel_ready=False)
            d.request_swap()
            old_beats=[]
            first_new=None
            swapped=False
            for _ in range(1000):
                s=d.tick(pixel_ready=rng.random() > 0.6)
                if not swapped and s.accepted:
                    old_beats.append(s.beat)
                elif swapped and s.accepted:
                    first_new=s.beat
                    break
                if s.swap_done:
                    swapped=True
            self.assertTrue(swapped, f'seed={seed}')
            self.assertEqual(len(old_beats),35)
            self.assertTrue(all(b.color == 0x123456 for b in old_beats))
            self.assertEqual((first_new.x,first_new.y,first_new.color), (0,0,0x998877))

    def test_single_pixel(self):
        d=self._ready_front(1,1,0x010101)
        d.clear_back(0x020202)
        d.tick(pixel_ready=False)
        d.request_swap()
        for _ in range(5):
            s=d.tick()
            if s.swap_done:
                break
        self.assertTrue(s.swap_done)
        d.tick()
        self.assertEqual(d.scan.peek().color,0x020202)

    def test_reset_during_pending_swap(self):
        d=self._ready_front()
        d.clear_back(0x334455)
        d.tick(pixel_ready=False)
        d.request_swap()
        s=d.tick(rst_n=False)
        self.assertFalse(s.swap_pending)
        self.assertFalse(d.display_initialized)
        self.assertFalse(d.render_initialized)
        self.assertFalse(d.swap_done)

    def test_back_triangle_does_not_change_front(self):
        d=self._ready_front(8,8)
        front=list(d.banks[d.front].fb)
        d.clear_back(0)
        d.draw_back(Triangle((0,0),(7,0),(0,7)),0xF00303)
        self.assertEqual(front,d.banks[d.front].fb)
        self.assertTrue(any(v==0xF00303 for v in d.banks[d.back].fb))

    def test_height_and_width_one(self):
        for w,h in [(1,7),(7,1),(1,1)]:
            d=self._ready_front(w,h,0xFFEEDD)
            self.assertEqual(d.banks[d.front].fb,[0xFFEEDD]*(w*h))

    def test_invalid_dimensions(self):
        for w,h in [(0,5),(5,0),(65537,1),(256,257)]:
            with self.assertRaises(ValueError):
                DoubleBufferedDisplay(w,h)


if __name__=='__main__':
    unittest.main()
