"""P51 tooling integrity tests, NOT hardware simulation results."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / 'tools' / 'p51_rtl_qualification.py'
spec = importlib.util.spec_from_file_location('p51_rtl_qualification', MODULE)
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


class P51QualificationTests(unittest.TestCase):
    def test_two_mutants_defined(self):
        self.assertEqual(set(q.MUTATIONS), {'stuck_low_valid', 'inverted_tie_choice'})

    def test_both_mutations_are_real_single_site_changes(self):
        src = q.RTL.read_text()
        for mutation in q.MUTATIONS:
            changed = q.mutated_source(src, mutation)
            self.assertNotEqual(src, changed)
            self.assertEqual(len(changed.splitlines()), len(src.splitlines()))
            self.assertEqual(changed.count('module a0_host_tx_fair_arbiter_p49'), 1)
            self.assertEqual(src.count('module a0_host_tx_fair_arbiter_p49'), 1)

    def test_mutation_site_must_be_unique(self):
        for mutation, (before, _, _) in q.MUTATIONS.items():
            with self.assertRaises(ValueError):
                q.mutated_source('no RTL here', mutation)
            with self.assertRaises(ValueError):
                q.mutated_source(before + '\n' + before, mutation)

    def test_negative_control_requires_runtime_pin_assertion(self):
        self.assertTrue(q.pin_mismatch_seen('FATAL P50 cycle 65 host_valid mismatch got=0 expected=1', 'stuck_low_valid'))
        self.assertTrue(q.pin_mismatch_seen('P50 cycle 1748 host_byte mismatch got=aa expected=bc', 'inverted_tie_choice'))
        self.assertFalse(q.pin_mismatch_seen('syntax error: compile failed', 'stuck_low_valid'))
        self.assertFalse(q.pin_mismatch_seen('P50 RTL TRACE PASS', 'stuck_low_valid'))
        self.assertFalse(q.pin_mismatch_seen('P50 cycle 65 host_byte mismatch', 'stuck_low_valid'))
        self.assertFalse(q.pin_mismatch_seen('P50 cycle 65 host_valid mismatch', 'inverted_tie_choice'))
        self.assertFalse(q.pin_mismatch_seen('P50 cycle abc host_valid mismatch', 'stuck_low_valid'))

    def test_missing_simulator_cannot_be_reported_as_pass(self):
        with tempfile.TemporaryDirectory(prefix='a0_p51_no_sim_') as td:
            p = Path(td)
            with mock.patch.object(q, 'real_tool', return_value=None):
                code = q.main(['--output', str(p)])
            self.assertEqual(code, 2)
            r = json.loads((p / 'receipt.json').read_text())
            self.assertEqual(r['status'], 'NOT_RUN')
            self.assertIsNone(r['available_tools']['iverilog'])
            self.assertEqual(r['canonical_p37'], 'NOT_CLAIMED')
            self.assertNotIn('backend', r)

    def test_output_cannot_write_into_source_tree(self):
        with tempfile.TemporaryDirectory(dir=q.ROOT) as td:
            self.assertEqual(q.main(['--output', str(Path(td))]), 1)

    def test_source_hashes_match_raw_contents(self):
        import hashlib
        for p in (q.TB, q.RTL):
            self.assertEqual(q.sha256(p), hashlib.sha256(p.read_bytes()).hexdigest())

    def test_p50_fixture_contains_real_competing_observations(self):
        import sys
        sys.path.insert(0, str(q.ROOT / 'tools'))
        from a0_fair_trace_p50 import build_trace, verify_trace
        trace, counts = build_trace(cycles=2400)
        self.assertGreater(counts['both_valid_cycles'], 100)
        self.assertGreater(counts['host_stalls'], 100)
        self.assertGreater(counts['completed_result_frames'], 20)
        self.assertGreater(counts['completed_telemetry_frames'], 20)
        self.assertEqual(verify_trace(trace)['cycles'], 2400)

if __name__ == '__main__':
    unittest.main()
