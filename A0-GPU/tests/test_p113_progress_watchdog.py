"""P113 semantic checks. Python tests do not claim that RTL ran."""
import pathlib
import random
import sys
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p113_progress_watchdog import ProgressWatchdog
from a0_p111_completion_watchdog import CompletionWatchdog

class ProgressWatchdogTests(unittest.TestCase):
    def setUp(self): self.m=ProgressWatchdog(max_wait=4)
    def accept(self,tag=42,op=2):
        return self.m.tick(accepting=True,accepted_tag=tag,opcode=op)
    def response(self,tag=42,error=False,ready=True):
        return self.m.tick(response_valid=True,response_tag=tag,response_error=error,response_ready=ready)
    def test_idle(self):
        for _ in range(100):self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().state,'IDLE')
    def test_present_progress_survives_100k_cycles(self):
        self.accept()
        for _ in range(100000):self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().timeouts,0)
        self.assertEqual(self.m.snapshot().present_pixels,100000)
        self.response()
        self.assertEqual(self.m.snapshot().completed,1)
    def test_present_stalls_do_not_timeout(self):
        self.accept()
        for _ in range(400):self.m.tick(pixel_valid=True,pixel_ready=False)
        self.assertEqual(self.m.snapshot().state,'WAIT')
        self.assertEqual(self.m.snapshot().age,0)
        self.response()
        self.assertEqual(self.m.snapshot().completed,1)
    def test_present_gap_at_threshold_fails(self):
        self.accept()
        for _ in range(3):self.m.tick()
        self.assertEqual(self.m.snapshot().state,'WAIT')
        self.m.tick()
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_present_progress_resets_age(self):
        self.accept()
        for _ in range(3):self.m.tick()
        self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().age,0)
        for _ in range(3):self.m.tick()
        self.assertEqual(self.m.snapshot().timeouts,0)
    def test_present_stall_preserves_existing_age(self):
        self.accept()
        self.m.tick();self.m.tick()
        for _ in range(100):self.m.tick(pixel_valid=True)
        self.assertEqual(self.m.snapshot().age,2)
        self.m.tick();self.m.tick()
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_triangle_pixel_activity_does_not_mask_timeout(self):
        self.accept(op=1)
        for _ in range(4): self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_clear_pixel_stall_does_not_mask_timeout(self):
        self.accept(op=0)
        for _ in range(4):self.m.tick(pixel_valid=True)
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_invalid_opcode_still_times_out(self):
        self.accept(op=3)
        for _ in range(4): self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_completion_before_timeout_has_priority(self):
        self.accept()
        for _ in range(3): self.m.tick()
        self.response()
        self.assertEqual(self.m.snapshot().completed,1)
        self.assertEqual(self.m.snapshot().timeouts,0)
    def test_held_response_survives_long_backpressure(self):
        self.accept()
        self.response(ready=False,error=True)
        for _ in range(1000):self.response(ready=False,error=True)
        self.response(error=True)
        self.assertEqual(self.m.snapshot().completed,1)
    def test_held_response_tag_change_fails(self):
        self.accept();self.response(ready=False);self.response(tag=41)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_mismatch_tag_fails(self):
        self.accept();self.response(tag=43)
        self.assertEqual(self.m.snapshot().tag_mismatches,1)
    def test_overlapping_command_fails(self):
        self.accept();self.accept(43)
        self.assertEqual(self.m.snapshot().protocol_faults,1)
    def test_orphan_response_fails(self):
        self.response()
        self.assertEqual(self.m.snapshot().last_fault_tag,42)
    def test_fault_latched_until_reset(self):
        self.response();previous=self.m.snapshot()
        for _ in range(100):self.m.tick(accepting=True,accepted_tag=7)
        self.assertEqual(self.m.snapshot(),previous)
        self.m.reset()
        self.assertEqual(self.m.snapshot().protocol_faults,0)
    def test_new_present_resets_pixel_count(self):
        self.accept();self.m.tick(pixel_valid=True,pixel_ready=True);self.response()
        self.accept(tag=99,op=2)
        self.assertEqual(self.m.snapshot().present_pixels,0)
    def test_present_age_without_valid_pixel_is_not_paused(self):
        self.accept()
        for _ in range(4): self.m.tick(pixel_ready=False)
        self.assertEqual(self.m.snapshot().timeouts,1)
    def test_non_present_parity_with_p111(self):
        rng=random.Random(113)
        for _ in range(50):
            old=CompletionWatchdog(max_wait=4);new=ProgressWatchdog(max_wait=4)
            tag=rng.randrange(65536)
            old.tick(accepting=True,accepted_tag=tag)
            new.tick(accepting=True,accepted_tag=tag,opcode=1)
            for _ in range(rng.randrange(0,6)):
                old.tick();new.tick(pixel_valid=True,pixel_ready=True)
            a,b=old.snapshot(),new.snapshot()
            self.assertEqual((a.state,a.active_tag,a.timeouts),(b.state,b.active_tag,b.timeouts))
    def test_invalid_inputs(self):
        for n in (0,-1,True,2**31):
            with self.assertRaises(ValueError):ProgressWatchdog(max_wait=n)
        for value in (-1,4,None,True):
            with self.assertRaises(ValueError):self.m.tick(opcode=value)
        with self.assertRaises(ValueError):self.m.tick(pixel_ready=1)
    def test_counter_saturation(self):
        self.accept();self.m.present_pixels=0xffffffff
        self.m.tick(pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().present_pixels,0xffffffff)
    def test_independent_opcode_snapshots(self):
        self.accept(op=2);self.m.tick(opcode=1,pixel_valid=True,pixel_ready=True)
        self.assertEqual(self.m.snapshot().present_pixels,1)
    def test_long_random_valid_session(self):
        rng=random.Random(113)
        for _ in range(200):
            tag=rng.randrange(65536)
            self.m.tick(accepting=True,accepted_tag=tag,opcode=2)
            for _ in range(25):
                self.m.tick(pixel_valid=True,pixel_ready=bool(rng.randrange(2)))
            self.m.tick(response_valid=True,response_tag=tag,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,200)
        self.assertEqual(self.m.snapshot().timeouts,0)
    def test_sources_are_separate_from_p111(self):
        rtl=(ROOT/'rtl/graphics/a0_command_progress_watchdog_p113.sv').read_text()
        top=(ROOT/'rtl/graphics/a0_host_fragment_dual_bank_diagnostics_p113.sv').read_text()
        self.assertIn('active_present_q && pixel_valid && pixel_ready',rtl)
        self.assertIn('active_present_q && pixel_valid && !pixel_ready',rtl)
        self.assertIn('.present_pixel_count(diagnostic_present_pixels)',top)
        self.assertIn('.cmd_opcode(cmd_opcode),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready)',top)
        self.assertNotIn('a0_command_completion_watchdog_p111 #(',top)

if __name__=='__main__':unittest.main()
