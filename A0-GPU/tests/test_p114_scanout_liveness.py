"""P114 Python-only behavioral tests; no claim of RTL execution."""
import importlib.util, pathlib, random, sys, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p114_scanout_liveness import ScanoutLiveness

class TestScanoutLiveness(unittest.TestCase):
    def setUp(self):
        self.m=ScanoutLiveness(width=3,height=2,max_idle=4,done_delay=3)
    def start(self):self.m.tick(active=True)
    def frame(self):
        self.start()
        for i in range(6): self.m.pixel(i,color=0x123456)
        self.m.tick(active=True,done=True)
    def test_idle(self):
        for _ in range(100):self.m.tick()
        self.assertEqual(self.m.snapshot().state,'IDLE')
    def test_valid_complete_frame(self):
        self.frame();s=self.m.snapshot()
        self.assertEqual((s.completed,s.accepted_pixels,s.state),(1,6,'IDLE'))
    def test_many_frames_after_command_completed(self):
        for _ in range(10):self.frame()
        self.assertEqual(self.m.snapshot().completed,10)
    def test_stream_stall_1000_cycles(self):
        self.start();self.m.pixel(0)
        for _ in range(1000):self.m.pixel(1,ready=False)
        self.assertEqual(self.m.snapshot().state,'STREAM')
        self.m.pixel(1)
        for i in range(2,6):self.m.pixel(i)
        self.m.tick(active=True,done=True)
        self.assertEqual(self.m.snapshot().stalled_cycles,1000)
        self.assertEqual(self.m.snapshot().completed,1)
    def test_no_progress_timeout(self):
        self.start()
        for _ in range(4):self.m.tick(active=True)
        self.assertEqual((self.m.snapshot().state,self.m.snapshot().fault_x),('FAULT',0))
        self.assertEqual(self.m.snapshot().timed_out,1)
    def test_timeout_after_first_pixel_reports_next_coordinate(self):
        self.start();self.m.pixel(0)
        for _ in range(4):self.m.tick(active=True)
        self.assertEqual((self.m.snapshot().fault_x,self.m.snapshot().fault_y),(1,0))
    def test_no_false_timeout_while_streaming(self):
        self.start()
        for i in range(6):
            for _ in range(3):self.m.tick(active=True)
            self.m.pixel(i)
        self.m.tick(active=True,done=True)
        self.assertEqual(self.m.snapshot().completed,1)
    def test_missing_done_timeout(self):
        self.start()
        for i in range(6):self.m.pixel(i)
        for _ in range(3):self.m.tick(active=True)
        self.assertEqual(self.m.snapshot().timed_out,1)
    def test_done_delayed_but_within_limit(self):
        self.start()
        for i in range(6):self.m.pixel(i)
        for _ in range(2):self.m.tick(active=True)
        self.m.tick(active=True,done=True)
        self.assertEqual(self.m.snapshot().completed,1)
    def test_early_done_fault(self):
        self.start();self.m.pixel(0);self.m.tick(active=True,done=True)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_scan_aborted_fault(self):
        self.start();self.m.pixel(0);self.m.tick(active=False)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_drop_valid_during_stall_fault(self):
        self.start();self.m.pixel(0,ready=False);self.m.tick(active=True)
        self.assertEqual(self.m.snapshot().state,'FAULT')
    def test_change_color_during_stall_fault(self):
        self.start();self.m.pixel(0,color=3,ready=False)
        self.m.pixel(0,color=4,ready=False)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_change_coordinates_during_stall_fault(self):
        self.start();self.m.pixel(0,ready=False);self.m.pixel(1,ready=False)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_change_flags_during_stall_fault(self):
        self.start();self.m.pixel(0,ready=False)
        self.m.tick(active=True,valid=True,x=0,y=0,color=0,sof=False)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_correct_released_stall(self):
        self.start();self.m.pixel(0,ready=False)
        self.m.pixel(0)
        self.assertEqual(self.m.snapshot().accepted_pixels,1)
    def test_wrong_position_fault(self):
        self.start();self.m.pixel(1)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_wrong_sof_fault(self):
        self.start();self.m.tick(active=True,valid=True,ready=True,x=0,y=0)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_wrong_eol_fault(self):
        self.start();self.m.tick(active=True,valid=True,ready=True,x=0,y=0,sof=True,eol=True)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_wrong_eof_fault(self):
        self.start();self.m.tick(active=True,valid=True,ready=True,x=0,y=0,sof=True,eof=True)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_orphan_pixel_fault(self):
        self.m.pixel(0)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_orphan_done_fault(self):
        self.m.tick(done=True)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_pixel_after_final_fault(self):
        self.start()
        for i in range(6):self.m.pixel(i)
        self.m.pixel(0)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_frozen_fault_until_reset(self):
        self.m.tick(done=True);a=self.m.snapshot()
        for _ in range(100):self.m.tick(active=True,valid=True)
        self.assertEqual(self.m.snapshot(),a)
        self.m.reset();self.frame()
        self.assertEqual(self.m.snapshot().completed,1)
    def test_bad_dimensions(self):
        for args in [dict(width=0),dict(height=-1),dict(width=32768),dict(width=300,height=300),
                     dict(max_idle=0),dict(done_delay=0),dict(width=True)]:
            with self.assertRaises(ValueError):ScanoutLiveness(**args)
    def test_bad_inputs(self):
        for args in [dict(active=1),dict(done=1),dict(x=-1),dict(y=65536),
                     dict(color=1<<24),dict(color=True)]:
            with self.assertRaises(ValueError):self.m.tick(**args)
    def test_saturating_counters(self):
        self.m.completed=(1<<32)-1;self.frame()
        self.assertEqual(self.m.snapshot().completed,(1<<32)-1)
        self.m.reset();self.m.stalled_cycles=(1<<32)-1;self.start();self.m.pixel(0,ready=False)
        self.assertEqual(self.m.snapshot().stalled_cycles,(1<<32)-1)
    def test_deterministic_randomized_frames(self):
        rng=random.Random(114);frames=100
        for _ in range(frames):
            self.start()
            for i in range(6):
                for _ in range(rng.randrange(0,3)):self.m.tick(active=True)
                color=rng.randrange(1<<24)
                for _ in range(rng.randrange(0,5)):self.m.pixel(i,color,False)
                self.m.pixel(i,color)
            self.m.tick(active=True,done=True)
        self.assertEqual(self.m.snapshot().completed,frames)
        self.assertEqual(self.m.snapshot().accepted_pixels,frames*6)
    def test_reflects_real_p104_present_semantics(self):
        # A PRESENT command may have COMPLETED already; liveness must still
        # track an entire frame. There is no cmd_valid/response input here.
        self.start()
        self.m.pixel(0)
        for _ in range(4):self.m.tick(active=True)
        self.assertEqual(self.m.snapshot().timed_out,1)
    def test_rtl_wires_and_modules(self):
        g=(ROOT/'rtl/graphics')
        mon=(g/'a0_scanout_liveness_guard_p114.sv').read_text()
        top=(g/'a0_host_fragment_dual_bank_diagnostics_p114.sv').read_text()
        self.assertIn('module a0_scanout_liveness_guard_p114',mon)
        self.assertIn('module a0_host_fragment_dual_bank_diagnostics_p114',top)
        self.assertIn('a0_scanout_liveness_guard_p114 #(',top)
        self.assertIn('.scan_active(scan_active)',top)
        self.assertIn('.frame_done(frame_done)',top)
        self.assertIn('.pixel_color(pixel_color)',top)
        self.assertIn('a0_command_progress_watchdog_p113 #(',top)

if __name__=='__main__':unittest.main()
