"""P104 software reference, no RTL execution is implied."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_p104_double_bank_reference import P104DoubleBankReference as G
from a0_p102_fragment_reference import FragmentState

TRI=((0,0),(4,0),(0,4))

class DoubleBankAcceptance(unittest.TestCase):
    def setUp(self):self.g=G(4,4)
    def first(self,color):
        self.g.clear(color)
        self.assertTrue(self.g.present())
        _,_,_,flip=self.g.step()
        self.assertTrue(flip)
        self.assertTrue(self.g.active)

    def test_reset_bank_assignment_and_initialization(self):
        self.assertEqual((self.g.display_bank,self.g.render_bank),(0,1))
        self.assertFalse(self.g.display_initialized)
        self.assertFalse(self.g.render_initialized)
        self.assertFalse(self.g.present())
        with self.assertRaises(RuntimeError):self.g.triangle(TRI,1,1)

    def test_clear_only_back_bank(self):
        self.g.clear(0x112233,0x456)
        self.assertEqual(self.g.banks[1].pixel(0,0),(0x112233,0x456))
        self.assertFalse(self.g.display_initialized)

    def test_first_swap_fires_one_frame(self):
        self.first(0x123456)
        self.assertEqual((self.g.display_bank,self.g.render_bank),(1,0))
        pixels=self.g.drain()
        self.assertEqual(len(pixels),16)
        self.assertTrue(pixels[0].first);self.assertTrue(pixels[-1].frame_end)
        self.assertEqual(sum(p.line_end for p in pixels),4)
        self.assertEqual({p.color for p in pixels},{0x123456})
        self.assertEqual(self.g.step(),(None,False,False,False))

    def test_back_bank_drawing_does_not_modify_front_scan(self):
        self.first(0x123456)
        self.g.clear(0xff0000)
        self.g.triangle(TRI,0x00ff00,10)
        self.assertEqual({p.color for p in self.g.drain()},{0x123456})
        self.assertEqual(self.g.banks[self.g.render_bank].pixel(1,1)[0],0x00ff00)

    def test_pixel_stable_during_ready_backpressure_with_back_clear(self):
        self.first(0xabc123)
        first=self.g.step(pixel_ready=False)[0]
        for k in range(25):
            if k==3:self.g.clear(0x0088ff)
            p,a,d,s=self.g.step(pixel_ready=False)
            self.assertEqual(p,first)
            self.assertFalse(a or d or s)
        self.assertEqual({p.color for p in self.g.drain()},{0xabc123})

    def test_present_queue_does_not_flip_until_last_beat_consumed(self):
        self.first(0x111111)
        self.g.clear(0x222222)
        self.assertTrue(self.g.present())
        self.assertFalse(self.g.present())
        for _ in range(12):
            self.g.step(pixel_ready=False)
            self.assertEqual(self.g.display_bank,1)
        pixels=[]
        for _ in range(16):
            p,a,d,s=self.g.step()
            pixels.append(p)
        self.assertTrue(d);self.assertEqual({p.color for p in pixels},{0x111111})
        self.assertEqual(self.g.display_bank,1)
        _,_,_,swap=self.g.step()
        self.assertTrue(swap)
        self.assertEqual(self.g.display_bank,0)
        self.assertEqual({p.color for p in self.g.drain()},{0x222222})

    def test_pending_swap_freezes_render(self):
        self.first(0)
        self.g.clear(0xffffff)
        self.assertTrue(self.g.present())
        with self.assertRaises(RuntimeError):self.g.clear(2)
        with self.assertRaises(RuntimeError):self.g.triangle(TRI,1,1)

    def test_scan_permission_only_at_acceptance(self):
        self.g.clear(0x1234)
        self.assertFalse(self.g.present(scan_enable=False))
        self.assertTrue(self.g.present(scan_enable=True))
        self.g.step()
        self.assertEqual(len(self.g.drain()),16)

    def test_render_bank_not_initial_after_first_flip(self):
        self.first(0xab)
        self.assertFalse(self.g.render_initialized)
        with self.assertRaises(RuntimeError):self.g.triangle(TRI,2,1)
        self.g.clear(0xcd)
        self.assertTrue(self.g.render_initialized)

    def test_depth_and_blend_isolate_across_frames(self):
        self.first(0x050505)
        self.g.clear(0x000000)
        self.g.triangle(TRI,0xff0000,0x100)
        self.g.triangle(TRI,0x00ff00,0x200) # farther => depth reject
        self.assertEqual(self.g.banks[self.g.render_bank].pixel(1,1)[0],0xff0000)
        self.assertEqual({p.color for p in self.g.drain()},{0x050505})
        self.assertTrue(self.g.present());self.g.step()
        colors=[p.color for p in self.g.drain()]
        self.assertIn(0xff0000,colors);self.assertIn(0x000000,colors)

    def test_reset_drops_pending_and_previous_ownership(self):
        self.first(0x777777)
        self.g.clear(0x123456)
        self.assertTrue(self.g.present())
        self.g.reset()
        self.assertEqual((self.g.display_bank,self.g.render_bank),(0,1))
        self.assertFalse(self.g.present())
        self.assertEqual(self.g.step(),(None,False,False,False))

    def test_two_frame_no_pixel_interleaving_under_random_stalls(self):
        for seed in range(12):
            r=random.Random(seed)
            g=G(5,3);g.clear(0x111111);g.present();g.step()
            g.clear(0x222222);g.present()
            stream=[];boundaries=[]
            for i in range(2000):
                pixel,accepted,done,sw=g.step(pixel_ready=bool(r.randrange(3)))
                if pixel is not None and accepted:stream.append(pixel.color)
                if done:boundaries.append(len(stream))
                if len(boundaries)==2:break
            self.assertEqual(boundaries,[15,30])
            self.assertEqual(stream,[0x111111]*15+[0x222222]*15)

    def test_random_repeated_frames_with_scissor_and_depth(self):
        r=random.Random(104)
        g=G(6,4)
        for frame in range(24):
            bg=r.randrange(1<<24)
            g.clear(bg)
            g.triangle(((0,0),(6,0),(0,4)),r.randrange(1<<24),r.randrange(500),
                       FragmentState(scissor=(1,1,3,2),blend=False))
            expected=g.banks[g.render_bank].colors.copy()
            self.assertTrue(g.present());_,_,_,swap=g.step()
            self.assertTrue(swap)
            out=g.drain(ready=lambda t:t%5 not in (0,1))
            self.assertEqual([p.color for p in out],expected)
        self.assertEqual(g.present_commits,g.completed_frames)

    def test_source_contains_required_bank_and_boundary_qualification(self):
        source=(Path(__file__).resolve().parents[1]/'rtl/graphics/a0_command_dual_bank_scanout_p104.sv').read_text()
        for fragment in ('a0_graphics_command_frontend_p43',
                         'a0_triangle_scissor_depth_blend_p102',
                         'a0_sync_frame_scanout_p42',
                         'render_bank=~display_bank_q',
                         'scan_running=scan_active_q && !scan_frame_done',
                         'swap_pending_q &&',
                         '(!scan_active_q || scan_frame_done)',
                         'if(scan_read_en && bank_read_valid[display_bank_q])'):
            self.assertIn(fragment,source)

if __name__=='__main__':unittest.main()
