"""P103 reference tests: software contract only, not SystemVerilog qualification."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command, CLEAR,TRIANGLE,PRESENT,INVALID
from a0_p102_fragment_reference import FragmentState,PixelTarget
from a0_p103_command_pixel_reference import P103CommandPixelModel

TRI=(0,0,4,0,0,4)

def cmd(op,tag,color=0,points=TRI):return Command(op,tag,color,points)

class P103SoftwareContract(unittest.TestCase):
    def setUp(self):self.g=P103CommandPixelModel(4,4)
    def clear(self,c=0,d=0xffffff):
        result,px=self.g.run_command(cmd(CLEAR,100,c),depth=d)
        self.assertEqual(result,(100,False));self.assertEqual(px,[])
    def capture(self,ready=lambda t: True):
        result,px=self.g.run_command(cmd(PRESENT,500),ready=ready)
        self.assertEqual(result,(500,False));return px

    def test_command_before_clear_fails_closed(self):
        for op in (TRIANGLE,PRESENT,INVALID):
            result,px=self.g.run_command(cmd(op,op+1))
            self.assertEqual(result,(op+1,True));self.assertFalse(px)
        self.assertFalse(self.g.framebuffer.initialized)

    def test_clear_and_single_present_exactly_one_frame(self):
        self.clear(0x123456)
        px=self.capture()
        self.assertEqual(len(px),16)
        self.assertEqual([(x,y) for x,y,*_ in px],[(x,y) for y in range(4) for x in range(4)])
        self.assertTrue(px[0][3]);self.assertTrue(px[-1][5])
        self.assertEqual(sum(i[3] for i in px),1)
        self.assertEqual(sum(i[5] for i in px),1)
        self.assertEqual(sum(i[4] for i in px),4)
        self.assertEqual({rgb for _,_,rgb,*_ in px},{0x123456})
        for _ in range(8):self.assertFalse(self.g.step().pixel_valid)

    def test_two_presents_are_two_frames_not_a_free_running_stream(self):
        self.clear(0x111111)
        a=self.capture()
        b=self.capture()
        self.assertEqual(a,b)
        self.assertEqual(len(a),16)

    def test_depth_rejection_and_blend_then_present(self):
        self.clear(0,0xffffff)
        self.assertEqual(self.g.run_command(cmd(TRIANGLE,1,0xff0000),depth=0x500)[0],(1,False))
        self.assertEqual(self.g.run_command(cmd(TRIANGLE,2,0x0000ff),depth=0x600)[0],(2,False))
        state=FragmentState(alpha=128,blend=True)
        self.assertEqual(self.g.run_command(cmd(TRIANGLE,3,0x00ff00),state=state,depth=0x400)[0],(3,False))
        pix=self.capture()
        self.assertEqual(next(rgb for x,y,rgb,*_ in pix if (x,y)==(1,1)),0x7f8000)
        self.assertEqual(self.g.framebuffer.pixel(1,1)[1],0x400)

    def test_fragment_scissor_and_depth_write_freeze(self):
        self.clear()
        st=FragmentState(depth_write=False,scissor=(1,1,2,2))
        self.g.run_command(cmd(TRIANGLE,7,0xabcd01),state=st,depth=10)
        pix=self.capture()
        self.assertEqual([ (x,y) for x,y,rgb,*_ in pix if rgb==0xabcd01 ],[(1,1)])
        self.assertEqual(self.g.framebuffer.pixel(1,1)[1],0xffffff)

    def test_backpressure_holds_pixel_until_accepted(self):
        self.clear(0x778899)
        self.g.step(command=cmd(PRESENT,9))
        for _ in range(3):self.g.step() # move frontend into OFFER
        # Present begins when allowed, then idle progress until first pixel
        for _ in range(20):
            obs=self.g.step(pixel_ready=False)
            if obs.pixel_valid:break
        else:self.fail('pixel was never offered')
        samples=[(obs.pixel_x,obs.pixel_y,obs.pixel_color)]
        for _ in range(6):
            obs=self.g.step(pixel_ready=False)
            self.assertTrue(obs.pixel_valid)
            samples.append((obs.pixel_x,obs.pixel_y,obs.pixel_color))
        self.assertEqual(len(set(samples)),1)

    def test_present_waits_for_scan_enable(self):
        self.clear()
        self.g.step(command=cmd(PRESENT,55),scan_enable=False)
        for _ in range(20):
            r=self.g.step(scan_enable=False)
            self.assertFalse(r.pixel_valid)
            self.assertFalse(r.completion_valid)
        self.assertFalse(self.g.present)
        for _ in range(5):
            r=self.g.step(scan_enable=True)
            if self.g.present:break
        self.assertTrue(self.g.present)

    def test_settings_latched_on_command_acceptance(self):
        self.clear()
        st=FragmentState(scissor=(1,1,1,1),depth_op=0)
        self.g.step(command=cmd(TRIANGLE,2,0xff00ee),fragment_state=st,depth=7)
        # All subsequent input wires differ; accepted values must persist.
        for _ in range(250):
            r=self.g.step(fragment_state=FragmentState(depth_op=3),depth=0xffffff)
            if r.completion_valid:break
        self.assertEqual(self.g.framebuffer.pixel(1,1),(0xff00ee,7))
        self.assertEqual(self.g.framebuffer.pixel(0,0),(0,0xffffff))

    def test_recover_after_reset_and_no_stale_pixel(self):
        self.clear(0x443322)
        self.g.step(command=cmd(PRESENT,99))
        for _ in range(3):self.g.step(pixel_ready=False)
        obs=self.g.step(rst_n=False)
        self.assertFalse(obs.pixel_valid);self.assertFalse(obs.initialized)
        for _ in range(20):self.assertFalse(self.g.step().pixel_valid)
        self.assertEqual(self.g.run_command(cmd(PRESENT,101))[0],(101,True))
        self.clear(0x101010)
        self.assertEqual(len(self.capture()),16)

    def test_completion_backpressure_holds_tag_and_error(self):
        self.g.step(command=cmd(INVALID,0xbeef),completion_ready=False)
        for _ in range(10):
            r=self.g.step(completion_ready=False)
            self.assertTrue(r.completion_valid)
            self.assertEqual(r.completion_tag,0xbeef)
            self.assertTrue(r.completion_error)
            self.assertFalse(r.cmd_ready)
        self.g.step(completion_ready=True)
        self.assertTrue(self.g.step().cmd_ready)

    def test_serial_frontend_rejects_overlapping_new_command(self):
        self.g.step(command=cmd(CLEAR,1,0x102030))
        for _ in range(6):
            out=self.g.step(command=cmd(CLEAR,2,0xabcdef),completion_ready=False)
            self.assertFalse(out.cmd_ready)
        for _ in range(50):
            out=self.g.step(completion_ready=False)
            if out.completion_valid: break
        self.assertTrue(out.completion_valid)
        self.assertEqual(out.completion_tag,1)
        self.assertEqual(self.g.framebuffer.pixel(0,0)[0],0x102030)

    def test_invalid_opcode_followed_by_valid_clear(self):
        self.assertEqual(self.g.run_command(cmd(INVALID,8))[0],(8,True))
        self.clear(0xabcdef)
        self.assertEqual(self.g.framebuffer.pixel(0,0)[0],0xabcdef)

    def test_randomized_3_frames_against_independent_pixel_target(self):
        rng=random.Random(103)
        self.clear()
        oracle=PixelTarget(4,4);oracle.clear(0,0xffffff)
        for frame in range(3):
            for t in range(12):
                points=tuple(rng.randint(-3,6) for _ in range(6))
                vv=((points[0],points[1]),(points[2],points[3]),(points[4],points[5]))
                color=rng.randrange(1<<24);depth=rng.randrange(1<<24)
                st=FragmentState(depth_op=rng.randrange(3),blend=bool(rng.randrange(2)),
                                 depth_write=bool(rng.randrange(2)),alpha=rng.randrange(256))
                oracle.draw_triangle(vv,color,depth,st)
                self.assertEqual(self.g.run_command(cmd(TRIANGLE,t,color,points),state=st,depth=depth)[0],(t,False))
            pixels=self.capture(ready=lambda k:k%7 not in (1,2,3))
            self.assertEqual([rgb for _,_,rgb,*_ in pixels],oracle.colors)

    def test_rtl_wiring_has_all_original_block_connections(self):
        rtl=Path(__file__).resolve().parents[1]/'rtl/graphics/a0_command_pixel_scanout_p103.sv'
        src=rtl.read_text()
        for name in ('a0_graphics_command_frontend_p43','a0_triangle_scissor_depth_blend_p102',
                     'a0_sync_frame_scanout_p42','scan_frame_done','cmd_valid && cmd_ready',
                     'present_active && !scan_frame_done','scan_read_valid <= scan_read_en && backend_read_valid'):
            self.assertIn(name,src)


if __name__=='__main__':unittest.main()
