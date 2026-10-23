"""P43 Python protocol and P42 integration REFERENCE checks; not RTL execution."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_graphics_command_p43 import GraphicsFrontend, Command, CLEAR, TRIANGLE, PRESENT, INVALID
from a0_graphics_pipeline_p43 import P43SoftwareAdapter
from a0_triangle_coverage_p38 import Triangle, rasterize


class TestP43Protocol(unittest.TestCase):
    def test_initial_idle(self):
        p=GraphicsFrontend(); s=p.outputs()
        self.assertTrue(s.cmd_ready)
        self.assertFalse(s.busy or s.completion_valid)
        self.assertFalse(s.clear_valid or s.tri_valid or s.swap_valid)

    def test_clear_wait_for_admission_and_done(self):
        p=GraphicsFrontend()
        p.tick(Command(CLEAR, 25, 0x123456))
        for _ in range(5):
            self.assertTrue(p.outputs().clear_valid)
            self.assertFalse(p.outputs().cmd_ready)
            p.tick(clear_done=True) # false early completion must not retire
        p.tick(clear_ready=True)
        self.assertFalse(p.outputs().clear_valid)
        p.tick(tri_done=True, swap_done=True)
        self.assertFalse(p.outputs().completion_valid)
        p.tick(clear_done=True)
        self.assertEqual((p.outputs().completion_tag,p.outputs().completion_error),(25,False))
        self.assertTrue(p.outputs().completion_valid)

    def test_triangle_payload_is_captured(self):
        p=GraphicsFrontend()
        payload=Command(TRIANGLE, 12, 0xFEDCBA, (-1,2,3,4,5,6))
        p.tick(payload)
        self.assertEqual(p.outputs().command,payload)
        for _ in range(11):
            p.tick(command=Command(TRIANGLE,99,0xABABAB,(9,)*6))
            self.assertEqual(p.outputs().command,payload)
        p.tick(tri_ready=True)
        p.tick(tri_done=True)
        self.assertEqual(p.outputs().completion_tag,12)

    def test_present_waits_for_swap_done(self):
        p=GraphicsFrontend(); p.tick(Command(PRESENT, 0x77))
        for _ in range(3):
            self.assertTrue(p.outputs().swap_valid)
            p.tick()
        p.tick(swap_ready=True)
        for _ in range(13):
            self.assertFalse(p.outputs().completion_valid)
            p.tick(clear_done=True, tri_done=True)
        p.tick(swap_done=True)
        self.assertTrue(p.outputs().completion_valid)
        self.assertEqual(p.outputs().completion_tag,0x77)

    def test_invalid_command_reports_error_without_effects(self):
        p=GraphicsFrontend(); p.tick(Command(INVALID,7))
        s=p.outputs()
        self.assertTrue(s.completion_valid and s.completion_error)
        self.assertFalse(s.clear_valid or s.tri_valid or s.swap_valid)
        p.tick(completion_ready=True)
        self.assertTrue(p.outputs().cmd_ready)

    def test_completion_backpressure_stable(self):
        p=GraphicsFrontend(); p.tick(Command(INVALID,3))
        old=p.outputs()
        for i in range(99):
            p.tick(command=Command(CLEAR,i),completion_ready=False)
            self.assertEqual(p.outputs(),old)
        p.tick(completion_ready=True)
        self.assertTrue(p.outputs().cmd_ready)

    def test_result_not_auto_consumed(self):
        p=GraphicsFrontend(); p.tick(Command(CLEAR,4))
        p.tick(clear_ready=True)
        p.tick(clear_done=True, completion_ready=False)
        for _ in range(3): p.tick(completion_ready=False)
        self.assertTrue(p.outputs().completion_valid)
        p.tick(completion_ready=True)
        self.assertTrue(p.outputs().cmd_ready)

    def test_reset_aborts_pending(self):
        for state in ('OFFER','WAIT_DONE','RESPONSE'):
            p=GraphicsFrontend(); p.tick(Command(CLEAR,99))
            if state in ('WAIT_DONE','RESPONSE'):p.tick(clear_ready=True)
            if state=='RESPONSE':p.tick(clear_done=True)
            p.tick(rst_n=False)
            self.assertTrue(p.outputs().cmd_ready)
            self.assertFalse(p.outputs().completion_valid)

    def test_tag_masking(self):
        p=GraphicsFrontend(tag_bits=3)
        p.tick(Command(INVALID,255))
        self.assertEqual(p.outputs().completion_tag,7)

    def test_bad_tag_width(self):
        with self.assertRaises(ValueError): GraphicsFrontend(0)

    def test_bad_payload(self):
        p=GraphicsFrontend()
        with self.assertRaises(ValueError):p.tick(Command(TRIANGLE,1,vertices=(0,1)))
        with self.assertRaises(ValueError):p.tick(Command(TRIANGLE,1,vertices=(0,0,0,0,0,32768)))

    def test_many_commands_order_and_exactly_once(self):
        p=GraphicsFrontend();rng=random.Random(438)
        commands=[Command(rng.randrange(4),i,rng.randrange(1<<24)) for i in range(125)]
        entered=[]; completed=[]; index=0; latency=0
        for _ in range(25000):
            before=p.outputs()
            if before.cmd_ready and index < len(commands):
                cmd=commands[index]; index+=1; entered.append(cmd.tag)
            else:cmd=None
            complete_handshake=before.completion_valid and rng.randrange(3)!=0
            if complete_handshake:completed.append((before.completion_tag,before.completion_error))
            if before.busy:latency+=1
            p.tick(command=cmd,completion_ready=complete_handshake,
                   clear_ready=rng.randrange(4)==0,tri_ready=rng.randrange(4)==0,
                   swap_ready=rng.randrange(4)==0,
                   clear_done=rng.randrange(6)==0,tri_done=rng.randrange(6)==0,
                   swap_done=rng.randrange(6)==0)
            if len(completed)==len(commands):break
        self.assertEqual(entered,list(range(len(commands))))
        self.assertEqual([c[0] for c in completed],list(range(len(commands))))
        self.assertEqual([c[1] for c in completed],[c.opcode==INVALID for c in commands])
        self.assertGreater(latency,100)




class TestP43ReferenceIntegration(unittest.TestCase):
    def test_clear_present_triangle_present(self):
        a=P43SoftwareAdapter(8,8)
        self.assertEqual(a.do(Command(CLEAR,101,0x113355)),(101,False))
        self.assertEqual(a.do(Command(PRESENT,102)),(102,False))
        self.assertTrue(a.display.display_initialized)
        self.assertEqual(a.display.banks[a.display.front].cells,[0x113355]*64)
        self.assertEqual(a.do(Command(CLEAR,103,0)),(103,False))
        tri=(0,0,7,0,0,7)
        self.assertEqual(a.do(Command(TRIANGLE,104,0xFFAA00,tri)),(104,False))
        self.assertEqual(a.do(Command(PRESENT,105)),(105,False))
        covered=set(rasterize(Triangle((0,0),(7,0),(0,7)),8,8))
        self.assertEqual(a.display.banks[a.display.front].cells,
                         [0xFFAA00 if (i%8,i//8) in covered else 0 for i in range(64)])

    def test_randomized_software_rendering(self):
        rng=random.Random(403)
        a=P43SoftwareAdapter(6,5)
        for frame in range(9):
            color=rng.randrange(1<<24)
            a.do(Command(CLEAR,frame*10,color))
            tri=tuple(rng.randrange(-2,8) for _ in range(6))
            paint=rng.randrange(1<<24)
            a.do(Command(TRIANGLE,frame*10+1,paint,tri))
            a.do(Command(PRESENT,frame*10+2))
            coverage=set(rasterize(Triangle((tri[0],tri[1]),(tri[2],tri[3]),(tri[4],tri[5])),6,5))
            self.assertEqual(a.display.banks[a.display.front].cells,
                             [paint if (i%6,i//6) in coverage else color for i in range(30)])

    def test_reject_present_and_triangle_before_clear(self):
        a=P43SoftwareAdapter(2,2)
        self.assertEqual(a.do(Command(PRESENT,5)),(5,True))
        self.assertEqual(a.do(Command(TRIANGLE,6)),(6,True))
        self.assertFalse(a.display.display_initialized)
        self.assertTrue(a.frontend.outputs().cmd_ready)

if __name__=='__main__':unittest.main()
