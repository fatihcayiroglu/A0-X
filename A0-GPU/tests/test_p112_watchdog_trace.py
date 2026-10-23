"""Python-only P112 trace preparation tests; none imply HDL execution."""
from pathlib import Path
from hashlib import sha256
import json
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p112_watchdog_trace import (generate_rows,serialize,parse_and_replay,
                                     CYCLES,SEED,MAX_WAIT,COLUMNS,WIDTHS)
TRACE=ROOT/'tests'/'vectors'/'p112_watchdog_4096.hex'
META=TRACE.with_suffix('.json')

class P112TraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.blob=TRACE.read_bytes()
        cls.meta=json.loads(META.read_text())

    def test_committed_vectors_reproducible(self):
        self.assertEqual(serialize(generate_rows()),self.blob)
    def test_sha256_pins_committed_vector(self):
        self.assertEqual(sha256(self.blob).hexdigest(),self.meta['sha256'])
    def test_replay_all_expected_outputs(self):
        self.assertEqual(parse_and_replay(self.blob),self.meta['coverage'])
    def test_cycle_and_field_count(self):
        self.assertEqual(len(self.blob.splitlines()),CYCLES)
        self.assertEqual(len(COLUMNS),16)
        self.assertEqual(len(WIDTHS),16)
    def test_all_required_scenarios_exercised(self):
        coverage=parse_and_replay(self.blob)
        self.assertGreater(coverage['fault_entries'],100)
        self.assertGreater(coverage['command_accepts'],100)
        self.assertGreater(coverage['stalled_response_cycles'],100)
        self.assertGreater(coverage['successful_response_cycles'],30)
        self.assertGreater(coverage['reset_cycles'],100)
        for kind in ('timeout_faults','tag_mismatch_faults','protocol_faults','completed_transactions'):
            self.assertGreater(coverage[kind],0,kind)
    def test_header_explicitly_disclaims_hdl_execution(self):
        self.assertEqual(self.meta['evidence_class'],'PYTHON_ORACLE_NOT_HDL_SIMULATION')
    def test_metadata_pin_names(self):
        self.assertEqual(self.meta['columns'],list(COLUMNS))
        self.assertEqual(self.meta['max_wait_cycles'],MAX_WAIT)
    def test_one_mismatched_expected_result_rejected(self):
        lines=self.blob.decode().splitlines()
        fields=lines[4].split(' ')
        fields[8]='0' if fields[8]=='1' else '1'
        lines[4]=' '.join(fields)
        with self.assertRaisesRegex(ValueError,'oracle'):
            parse_and_replay(('\n'.join(lines)+'\n').encode())
    def test_wrong_tag_in_input_rejected_by_replay(self):
        lines=self.blob.decode().splitlines()
        fields=lines[4].split(' ')
        fields[6]='ff'
        lines[4]=' '.join(fields)
        with self.assertRaises(ValueError):
            parse_and_replay(('\n'.join(lines)+'\n').encode())
    def test_truncated_row_rejected(self):
        lines=self.blob.decode().splitlines()
        lines[3]=' '.join(lines[3].split(' ')[:-1])
        with self.assertRaisesRegex(ValueError,'column'):
            parse_and_replay(('\n'.join(lines)+'\n').encode())
    def test_extra_field_rejected(self):
        with self.assertRaisesRegex(ValueError,'column'):
            parse_and_replay(self.blob+b'1\n')
    def test_noncanonical_uppercase_rejected(self):
        lines=self.blob.decode().splitlines()
        lines[3]=lines[3].replace('abcd','ABCD')
        with self.assertRaisesRegex(ValueError,'noncanonical'):
            parse_and_replay(('\n'.join(lines)+'\n').encode())
    def test_out_of_range_boolean_rejected(self):
        lines=self.blob.decode().splitlines()
        fields=lines[3].split(' ')
        fields[0]='2'
        lines[3]=' '.join(fields)
        with self.assertRaisesRegex(ValueError,'out of range'):
            parse_and_replay(('\n'.join(lines)+'\n').encode())
    def test_invalid_non_ascii_rejected(self):
        with self.assertRaisesRegex(ValueError,'non-ascii'):
            parse_and_replay(b'\xff\n')
    def test_empty_trace_rejected(self):
        with self.assertRaisesRegex(ValueError,'empty'):
            parse_and_replay(b'')
    def test_same_seed_reproduces(self):
        self.assertEqual(generate_rows(cycles=300,seed=SEED),generate_rows(cycles=300,seed=SEED))
    def test_different_seed_changes_trace(self):
        self.assertNotEqual(generate_rows(cycles=300,seed=SEED),generate_rows(cycles=300,seed=SEED+1))
    def test_invalid_generator_params_rejected(self):
        for cycles in (0,99,100001,True,'4096'):
            with self.subTest(cycles=cycles), self.assertRaises(ValueError):
                generate_rows(cycles=cycles)
    def test_generate_and_replay_odd_length(self):
        sample=serialize(generate_rows(cycles=255))
        self.assertEqual(parse_and_replay(sample)['cycles'],255)

if __name__=='__main__':unittest.main()
