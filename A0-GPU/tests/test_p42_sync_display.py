"""P42 reference checks. These cannot establish RTL or FPGA correctness."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_sync_display_p42 import SyncFrameRAM, SyncScanout, SyncDisplay
from a0_triangle_coverage_p38 import Triangle, rasterize


class TestP42SyncRam(unittest.TestCase):
    def test_uninitialized_read_suppressed(self):
        r = SyncFrameRAM(7)
        r.tick(read_addr=0)
        self.assertFalse(r.read_valid)

    def test_clear_requires_exactly_depth_writes(self):
        for depth in (1, 2, 7, 33):
            r = SyncFrameRAM(depth)
            r.tick(clear_color=0x123456)
            self.assertFalse(r.initialized)
            for _ in range(depth-1):
                r.tick()
                self.assertFalse(r.initialized)
                self.assertFalse(r.clear_done)
            r.tick()
            self.assertTrue(r.initialized)
            self.assertTrue(r.clear_done)
            self.assertEqual(r.cells, [0x123456]*depth)

    def test_read_has_clock_edge_latency_and_holds(self):
        r = SyncFrameRAM(4)
        r.clear(0x001122)
        r.tick(write_addr=2, write_color=0xCCBBAA)
        self.assertFalse(r.read_valid)
        r.tick(read_addr=2)
        self.assertTrue(r.read_valid)
        self.assertEqual(r.read_data, 0xCCBBAA)
        r.tick()
        self.assertFalse(r.read_valid)
        self.assertEqual(r.read_data, 0xCCBBAA)

    def test_writes_not_allowed_during_clear(self):
        r = SyncFrameRAM(3)
        r.clear(0)
        r.tick(clear_color=0xFFFFFF)
        for _ in range(3):
            self.assertFalse(r.write_ready())
            r.tick(write_addr=0, write_color=0x777777)
        self.assertEqual(r.cells, [0xFFFFFF]*3)

    def test_out_of_range_request_returns_no_valid(self):
        r = SyncFrameRAM(3)
        r.clear(1)
        r.tick(read_addr=3, write_addr=4, write_color=33)
        self.assertFalse(r.read_valid)
        self.assertEqual(r.cells, [1,1,1])

    def test_reset_invalidates_contents_not_assumed_zero(self):
        r=SyncFrameRAM(2)
        r.clear(0xFFEEDD)
        r.tick(rst_n=False)
        self.assertFalse(r.initialized)
        self.assertEqual(r.cells,[0xFFEEDD]*2)
        self.assertFalse(r.read_valid)
        r.tick(read_addr=0)
        self.assertFalse(r.read_valid)


class TestP42SyncScanout(unittest.TestCase):
    def setup_scan(self, width, height, color):
        ram=SyncFrameRAM(width*height)
        ram.clear(color)
        return ram,SyncScanout(width,height)

    def test_initial_read_not_immediate(self):
        ram,s=self.setup_scan(2,2,0xAA)
        self.assertIsNone(s.peek())
        for _ in range(2):
            beat,accepted=s.tick(ram,enable=True,ready=False)
            self.assertFalse(accepted)
            self.assertIsNone(beat)
        s.tick(ram,enable=True,ready=False)
        self.assertEqual(s.peek().color,0xAA)

    def test_backpressure_holds_every_field(self):
        ram,s=self.setup_scan(3,2,0x112233)
        for _ in range(3):
            s.tick(ram,enable=True,ready=False)
        before=s.peek()
        self.assertIsNotNone(before)
        for _ in range(25):
            beat,accepted=s.tick(ram,enable=True,ready=False)
            self.assertFalse(accepted)
            self.assertEqual(beat,before)
            self.assertEqual(s.peek(),before)

    def test_row_major_and_frame_markers(self):
        ram,s=self.setup_scan(4,3,0)
        for i in range(12):
            ram.tick(write_addr=i,write_color=i+100)
        out=[]; done=0
        for _ in range(120):
            beat,accepted=s.tick(ram,enable=True)
            if accepted: out.append(beat)
            if s.frame_done: done+=1
            if len(out)==12: break
        self.assertEqual(len(out),12)
        self.assertEqual([(v.x,v.y,v.color) for v in out],
                         [(i%4,i//4,i+100) for i in range(12)])
        self.assertEqual([i for i,v in enumerate(out) if v.sof],[0])
        self.assertEqual([i for i,v in enumerate(out) if v.eol],[3,7,11])
        self.assertEqual([i for i,v in enumerate(out) if v.eof],[11])
        self.assertEqual(done,1)

    def test_disable_aborts_and_restarts_at_origin(self):
        ram,s=self.setup_scan(3,2,0x887766)
        for _ in range(8): s.tick(ram,enable=True)
        s.tick(ram,enable=False)
        self.assertIsNone(s.peek(enable=False))
        beats=[]
        for _ in range(10):
            beat,accepted=s.tick(ram,enable=True)
            if accepted: beats.append(beat)
        self.assertTrue(beats)
        self.assertEqual((beats[0].x,beats[0].y),(0,0))

    def test_single_pixel_continuous_frames(self):
        ram,s=self.setup_scan(1,1,0x445566)
        beats=[]
        for _ in range(18):
            beat,accepted=s.tick(ram,enable=True)
            if accepted: beats.append(beat)
        self.assertGreaterEqual(len(beats),3)
        self.assertTrue(all(v.sof and v.eol and v.eof for v in beats))


class TestP42IntegratedReference(unittest.TestCase):
    def _ready(self,w=4,h=3,color=0x123456):
        d=SyncDisplay(w,h)
        d.clear_back(color)
        d.swap_when_disabled()
        return d

    def test_front_undefined_until_first_swap(self):
        d=SyncDisplay(2,2)
        for _ in range(10):
            s=d.tick(swap_valid=True)
            self.assertFalse(s.swap_accepted)
            self.assertFalse(s.accepted)

    def test_midframe_swap_preserves_old_frame(self):
        d=self._ready()
        d.clear_back(0xABCDEF)
        # Start scan to make EOF the only legal active-display swap boundary.
        for _ in range(3): d.tick(pixel_ready=False)
        s=d.tick(pixel_ready=False,swap_valid=True)
        self.assertTrue(s.swap_accepted)
        old=[]; first_new=None; swapped=False
        for _ in range(140):
            s=d.tick()
            if s.accepted:
                if not swapped: old.append(s.beat)
                elif first_new is None: first_new=s.beat
            if s.swap_done: swapped=True
            if first_new is not None: break
        self.assertTrue(swapped)
        self.assertEqual(len(old),12)
        self.assertEqual([p.color for p in old],[0x123456]*12)
        self.assertEqual((first_new.x,first_new.y,first_new.color),(0,0,0xABCDEF))

    def test_pending_prevents_mutation_and_duplicate_swap(self):
        d=self._ready()
        d.clear_back(0xEEEEEE)
        for _ in range(4): d.tick(pixel_ready=False)
        d.tick(pixel_ready=False,swap_valid=True)
        back_before=list(d.banks[d.back].cells)
        for _ in range(13):
            s=d.tick(pixel_ready=False,swap_valid=True,clear_color=0xFFFFFF)
            self.assertFalse(s.swap_accepted)
            self.assertFalse(s.swap_done)
            self.assertEqual(d.banks[d.back].cells,back_before)

    def test_draw_back_isolation_and_first_pixel(self):
        d=self._ready(w=8,h=8,color=0x010203)
        front_before=list(d.banks[d.front].cells)
        d.clear_back(0)
        triangle=Triangle((0,0),(7,0),(0,7))
        d.draw_back(triangle,0xFF5500)
        self.assertEqual(d.banks[d.front].cells,front_before)
        expected=set(rasterize(triangle,8,8))
        for y in range(8):
            for x in range(8):
                expected_color=0xFF5500 if (x,y) in expected else 0
                self.assertEqual(d.banks[d.back].cells[y*8+x],expected_color)
        d.swap_when_disabled()
        out=[]
        for _ in range(260):
            s=d.tick()
            if s.accepted: out.append(s.beat)
            if len(out)==64: break
        self.assertEqual(len(out),64)
        self.assertEqual([p.color for p in out],d.banks[d.front].cells)

    def test_seeded_backpressure_swap(self):
        for seed in range(7):
            rng=random.Random(seed)
            d=self._ready(w=6,h=5,color=0x114466)
            d.clear_back(0x667799)
            for _ in range(5): d.tick(pixel_ready=False)
            d.tick(pixel_ready=False,swap_valid=True)
            before=[]; after=[]; swapped=False
            for _ in range(1200):
                s=d.tick(pixel_ready=rng.random()>0.5)
                if s.accepted:
                    (after if swapped else before).append(s.beat)
                if s.swap_done: swapped=True
                if after: break
            self.assertEqual(len(before),30,seed)
            self.assertTrue(all(b.color==0x114466 for b in before),seed)
            self.assertEqual((after[0].x,after[0].y,after[0].color),(0,0,0x667799))

    def test_invalid_geometry(self):
        for w,h in ((0,2),(2,0),(65537,1),(257,256)):
            with self.assertRaises(ValueError): SyncDisplay(w,h)

if __name__=='__main__': unittest.main()
