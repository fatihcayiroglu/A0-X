"""P115 software contract tests (NOT HDL simulator proof)."""
import pathlib,random,sys,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p115_frame_event_audit import FrameEventAudit,MAX

class AuditCases(unittest.TestCase):
    def setUp(self):self.m=FrameEventAudit()
    def event(self,**overrides):
        a=dict(active=True,done=True,crc_valid=True,crc=0x12345678,
               liveness_pending=True,liveness_completed=self.m.good+self.m.untrusted)
        a.update(overrides);self.m.tick(**a)
    def acknowledge(self,completed):
        self.m.tick(liveness_completed=completed)
    def good(self):
        old=self.m.good
        self.event(liveness_completed=old)
        self.acknowledge(old+1)
    def test_reset_idle(self):
        for _ in range(100):self.m.tick()
        self.assertEqual(self.m.snapshot().good,0)
        self.assertFalse(self.m.snapshot().fault)
    def test_clean_two_phase(self):
        self.event()
        self.assertTrue(self.m.snapshot().pending)
        self.assertEqual(self.m.snapshot().good,0)
        self.acknowledge(1)
        self.assertEqual(self.m.snapshot().good,1)
        self.assertFalse(self.m.snapshot().pending)
        self.assertEqual(self.m.snapshot().last_crc,0x12345678)
    def test_many_frames(self):
        for _ in range(300):self.good()
        self.assertEqual(self.m.snapshot().good,300)
        self.assertFalse(self.m.snapshot().fault)
    def test_missing_crc_event(self):
        self.event(crc_valid=False)
        self.assertTrue(self.m.snapshot().fault)
        self.assertEqual(self.m.snapshot().event_faults,1)
    def test_crc_without_frame_done(self):
        self.event(done=False)
        self.assertEqual(self.m.snapshot().event_faults,1)
    def test_pair_without_active(self):
        self.event(active=False)
        self.assertTrue(self.m.snapshot().fault)
    def test_pair_without_liveness_pending(self):
        self.event(liveness_pending=False)
        self.assertTrue(self.m.snapshot().fault)
    def test_pair_when_liveness_faulted(self):
        self.event(liveness_fault=True)
        s=self.m.snapshot()
        self.assertEqual(s.liveness_faults,1)
        self.assertEqual(s.event_faults,1)
    def test_missing_completion_increment(self):
        self.event()
        self.acknowledge(0)
        s=self.m.snapshot();self.assertTrue(s.fault)
        self.assertEqual((s.good,s.untrusted,s.event_faults),(0,1,1))
    def test_skipped_completion_increment(self):
        self.event();self.acknowledge(2)
        self.assertEqual(self.m.snapshot().event_faults,1)
    def test_good_crc_but_bad_liveness(self):
        self.event()
        self.m.tick(liveness_completed=1,liveness_fault=True)
        self.assertTrue(self.m.snapshot().fault)
        self.assertEqual(self.m.snapshot().untrusted,1)
    def test_bad_crc_not_matched_good(self):
        self.event(crc_error=True)
        self.assertEqual(self.m.snapshot().crc_errors,1)
        self.acknowledge(1)
        self.assertEqual((self.m.snapshot().good,self.m.snapshot().untrusted),(0,1))
        self.assertTrue(self.m.snapshot().fault) # CRC errors are sticky too
    def test_telemetry_drop_invalidates_epoch(self):
        self.good()
        self.m.tick(telemetry_dropped=3)
        self.assertTrue(self.m.snapshot().fault)
        self.assertEqual(self.m.snapshot().telemetry_lost,3)
        self.assertEqual(self.m.snapshot().good,1) # matched != delivered
    def test_drop_counter_increment_delta(self):
        self.m.tick(telemetry_dropped=1)
        self.m.tick(telemetry_dropped=5)
        self.assertEqual(self.m.snapshot().telemetry_lost,5)
    def test_telemetry_rollback_is_fault(self):
        self.m.tick(telemetry_dropped=5)
        self.m.tick(telemetry_dropped=2)
        self.assertEqual(self.m.snapshot().event_faults,1)
    def test_liveness_fault_counts_rising_once(self):
        for _ in range(100):self.m.tick(liveness_fault=True)
        self.assertEqual(self.m.snapshot().liveness_faults,1)
    def test_liveness_fault_two_rises(self):
        self.m.tick(liveness_fault=True)
        self.m.tick(liveness_fault=False)
        self.m.tick(liveness_fault=True)
        self.assertEqual(self.m.snapshot().liveness_faults,2)
    def test_no_success_on_pair_before_confirmation(self):
        self.event()
        self.assertEqual(self.m.snapshot().good,0)
    def test_crc_snapshot_only_on_accepted_pair(self):
        self.event(done=False,crc=0xdeadbeef)
        self.assertEqual(self.m.snapshot().last_crc,0)
    def test_reset_clears_all(self):
        self.event();self.acknowledge(0)
        self.m.tick(telemetry_dropped=9)
        self.m.reset();self.good()
        self.assertEqual(self.m.snapshot().good,1)
        self.assertFalse(self.m.snapshot().fault)
    def test_saturation(self):
        self.m.good=MAX;self.event(liveness_completed=MAX);self.acknowledge(MAX)
        self.assertEqual(self.m.snapshot().good,MAX)
        self.m.reset();self.m.telemetry_lost=MAX-1;self.m.tick(telemetry_dropped=100)
        self.assertEqual(self.m.snapshot().telemetry_lost,MAX)
    def test_bad_inputs(self):
        for vals in [dict(done=1),dict(crc=-1),dict(crc=1<<32),
                     dict(liveness_completed=-1),dict(telemetry_dropped=True),
                     dict(frame_done=True)]:
            with self.assertRaises((ValueError,TypeError)):self.m.tick(**vals)
    def test_random_clean_and_bad_crc(self):
        rng=random.Random(115)
        count=0;bad=0
        for _ in range(400):
            is_bad=bool(rng.randrange(3)==0)
            self.m.tick(active=True,done=True,crc_valid=True,
                        crc=rng.randrange(1<<32),crc_error=is_bad,
                        liveness_pending=True,liveness_completed=count+bad)
            self.m.tick(liveness_completed=count+bad+1)
            if is_bad:bad+=1
            else:count+=1
        self.assertEqual((self.m.snapshot().good,self.m.snapshot().untrusted),(count,bad))
        self.assertEqual(self.m.snapshot().event_faults,0)

if __name__=='__main__':unittest.main()
