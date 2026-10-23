"""Software-side contract and adversarial cases for P111 RTL observer."""
import importlib.util
import random
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p111_completion_watchdog import CompletionWatchdog


class CompletionMonitorTests(unittest.TestCase):
    def setUp(self):
        self.m=CompletionWatchdog(max_wait=5)

    def test_no_activity_is_quiet(self):
        for _ in range(100): self.m.tick()
        self.assertEqual(self.m.snapshot().state,'IDLE')
        self.assertEqual(self.m.snapshot().timeouts,0)

    def test_immediate_result_is_allowed_next_clock(self):
        self.m.tick(accepting=True,accepted_tag=12)
        self.m.tick(response_valid=True,response_tag=12,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,1)

    def test_multiple_distinct_commands(self):
        for tag in range(20):
            self.m.tick(accepting=True,accepted_tag=tag)
            self.m.tick(response_valid=True,response_tag=tag,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,20)
        self.assertEqual(self.m.snapshot().state,'IDLE')

    def test_host_backpressure_never_times_out_offered_result(self):
        self.m.tick(accepting=True,accepted_tag=123)
        self.m.tick(response_valid=True,response_tag=123,response_error=True)
        for _ in range(1000):
            self.m.tick(response_valid=True,response_tag=123,response_error=True)
        self.assertEqual(self.m.snapshot().timeouts,0)
        self.assertEqual(self.m.snapshot().state,'HOLD')
        self.m.tick(response_valid=True,response_tag=123,response_error=True,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,1)

    def test_tag_mismatch_fails(self):
        self.m.tick(accepting=True,accepted_tag=17)
        self.m.tick(response_valid=True,response_tag=18,response_ready=True)
        self.assertEqual(self.m.snapshot().tag_mismatches,1)
        self.assertEqual(self.m.snapshot().last_fault_tag,18)
        self.assertEqual(self.m.snapshot().state,'FAULT')

    def test_orphan_response_fails(self):
        self.m.tick(response_valid=True,response_tag=91)
        self.assertEqual(self.m.snapshot().protocol_faults,1)

    def test_unaccepted_command_does_not_start_timer(self):
        for _ in range(8):
            self.m.tick(accepting=False,accepted_tag=123)
        self.assertEqual(self.m.snapshot().state,'IDLE')

    def test_one_outstanding_rejects_overlap(self):
        self.m.tick(accepting=True,accepted_tag=1)
        self.m.tick(accepting=True,accepted_tag=2)
        self.assertEqual(self.m.snapshot().last_fault_tag,2)
        self.assertEqual(self.m.snapshot().protocol_faults,1)

    def test_exact_timeout_boundary(self):
        self.m.tick(accepting=True,accepted_tag=4)
        for _ in range(4):
            self.m.tick()
            self.assertEqual(self.m.snapshot().state,'WAIT')
        self.m.tick()
        self.assertEqual(self.m.snapshot().timeouts,1)
        self.assertEqual(self.m.snapshot().last_fault_tag,4)

    def test_response_on_last_cycle_beats_timeout(self):
        self.m.tick(accepting=True,accepted_tag=4)
        for _ in range(4): self.m.tick()
        self.m.tick(response_valid=True,response_tag=4,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,1)
        self.assertEqual(self.m.snapshot().timeouts,0)

    def test_response_with_error_is_still_completion(self):
        self.m.tick(accepting=True,accepted_tag=65535)
        self.m.tick(response_valid=True,response_tag=65535,response_error=True,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,1)

    def test_hold_valid_must_not_drop(self):
        self.m.tick(accepting=True,accepted_tag=40)
        self.m.tick(response_valid=True,response_tag=40)
        self.m.tick()
        self.assertEqual(self.m.snapshot().protocol_faults,1)

    def test_hold_tag_must_not_change(self):
        self.m.tick(accepting=True,accepted_tag=40)
        self.m.tick(response_valid=True,response_tag=40)
        self.m.tick(response_valid=True,response_tag=41)
        self.assertEqual(self.m.snapshot().protocol_faults,1)

    def test_hold_error_bit_must_not_change(self):
        self.m.tick(accepting=True,accepted_tag=40)
        self.m.tick(response_valid=True,response_tag=40,response_error=True)
        self.m.tick(response_valid=True,response_tag=40,response_error=False)
        self.assertEqual(self.m.snapshot().protocol_faults,1)

    def test_held_result_disallows_new_command(self):
        self.m.tick(accepting=True,accepted_tag=40)
        self.m.tick(response_valid=True,response_tag=40)
        self.m.tick(accepting=True,accepted_tag=41,response_valid=True,response_tag=40)
        self.assertEqual(self.m.snapshot().state,'FAULT')

    def test_terminal_fault_unchanged_without_reset(self):
        self.m.tick(response_valid=True,response_tag=6)
        before=self.m.snapshot()
        for i in range(100):
            self.m.tick(accepting=True,accepted_tag=i,
                        response_valid=True,response_tag=i,response_ready=True)
        self.assertEqual(self.m.snapshot(),before)

    def test_reset_clears_fault_and_counters(self):
        self.m.tick(response_valid=True,response_tag=6)
        self.m.reset()
        self.m.tick(accepting=True,accepted_tag=12)
        self.m.tick(response_valid=True,response_tag=12,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,1)
        self.assertEqual(self.m.snapshot().protocol_faults,0)

    def test_max_wait_one(self):
        m=CompletionWatchdog(max_wait=1)
        m.tick(accepting=True,accepted_tag=7)
        m.tick()
        self.assertEqual(m.snapshot().timeouts,1)

    def test_reject_bad_parameters(self):
        for value in (-1,0,True,'4',2**31):
            with self.subTest(value=value),self.assertRaises(ValueError):
                CompletionWatchdog(max_wait=value)

    def test_reject_out_of_range_tag(self):
        for value in (-1,65536,None):
            with self.subTest(value=value),self.assertRaises(ValueError):
                self.m.tick(accepting=True,accepted_tag=value)

    def test_reject_non_bool_handshake(self):
        with self.assertRaises(ValueError):
            self.m.tick(accepting=1)

    def test_random_valid_traffic_with_long_result_stalls(self):
        rng=random.Random(111)
        completed=0
        for _ in range(2000):
            tag=rng.randrange(65536)
            self.m.tick(accepting=True,accepted_tag=tag)
            for _ in range(rng.randrange(0,4)):
                self.m.tick()
            err=bool(rng.randrange(2))
            for _ in range(rng.randrange(0,80)):
                self.m.tick(response_valid=True,response_tag=tag,response_error=err)
            self.m.tick(response_valid=True,response_tag=tag,
                        response_error=err,response_ready=True)
            completed+=1
        self.assertEqual(self.m.snapshot().completed,completed)
        self.assertEqual(self.m.snapshot().timeouts,0)
        self.assertEqual(self.m.snapshot().protocol_faults,0)

    def test_random_mutated_tags_always_fail(self):
        rng=random.Random(112)
        for _ in range(200):
            m=CompletionWatchdog()
            tag=rng.randrange(65536)
            m.tick(accepting=True,accepted_tag=tag)
            m.tick(response_valid=True,response_tag=tag^1,response_ready=True)
            self.assertEqual(m.snapshot().tag_mismatches,1)

    def test_timeout_not_affected_by_readiness_without_valid(self):
        self.m.tick(accepting=True,accepted_tag=9)
        for _ in range(5):
            self.m.tick(response_ready=True)
        self.assertEqual(self.m.snapshot().timeouts,1)

    def test_counters_saturate(self):
        self.m.completed=0xffffffff
        self.m.tick(accepting=True,accepted_tag=9)
        self.m.tick(response_valid=True,response_tag=9,response_ready=True)
        self.assertEqual(self.m.snapshot().completed,0xffffffff)

if __name__=='__main__': unittest.main()
