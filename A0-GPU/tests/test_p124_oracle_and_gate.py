"""P124 pure Python oracle and fail-closed evidence controls (NOT RTL proof)."""
from __future__ import annotations
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
sys.path.insert(0,str(ROOT/'tools'))
import run_p124_depth5_loss_notice_race as runner
from a0_p122_packet_oracle import frame,loss_notice,decode
spec=importlib.util.spec_from_file_location('p124_gate',ROOT/'tools/a0_p124_rtl_qualification.py')
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def witness(raws=None,marker=True,race=True):
    packets=runner.EXPECTED if raws is None else raws
    lines=[f'P124_PACKET {i} {p.hex()}' for i,p in enumerate(packets)]
    if race:lines.append(runner.RACE)
    if marker:lines.append(runner.MARKER)
    return '\n'.join(lines)+'\n'


class Oracle(unittest.TestCase):
    def test_eight_independently_decodable_packets(self):
        self.assertEqual(len(runner.EXPECTED),8)
        self.assertTrue(runner.assess_stream(witness())[0])
        parsed=[decode(p) for p in runner.EXPECTED]
        self.assertEqual([p['type'] for p in parsed],['frame']*5+['loss']*2+['frame'])
        self.assertEqual([p['sequence'] for p in parsed],[0,1,2,3,4,6,7,7])
        self.assertEqual([p['dropped'] for p in parsed[5:]],[1,2,2])
        self.assertEqual([p['good'] for p in parsed],[11]*5+[99,99,123])

    def test_missing_race_marker(self):
        self.assertFalse(runner.assess_stream(witness(race=False))[0])

    def test_duplicate_race_marker(self):
        self.assertFalse(runner.assess_stream(witness()+runner.RACE+'\n')[0])

    def test_missing_completion_marker(self):
        self.assertFalse(runner.assess_stream(witness(marker=False))[0])

    def test_duplicate_completion_marker(self):
        self.assertFalse(runner.assess_stream(witness()+runner.MARKER+'\n')[0])

    def test_missing_packet(self):
        self.assertFalse(runner.assess_stream(witness(runner.EXPECTED[:-1]))[0])

    def test_extra_packet(self):
        self.assertFalse(runner.assess_stream(witness(runner.EXPECTED+[runner.EXPECTED[0]]))[0])

    def test_crc_bit_flip(self):
        p=list(runner.EXPECTED);raw=bytearray(p[5]);raw[15]^=0x80;p[5]=bytes(raw)
        self.assertIn('CRC32',runner.assess_stream(witness(p))[1])

    def test_silent_dropped_count_change_with_valid_crc(self):
        p=list(runner.EXPECTED)
        p[6]=loss_notice(sequence=7,dropped=1,good=99,bad=98,aborted=97)
        self.assertFalse(runner.assess_stream(witness(p))[0])

    def test_silent_sequence_change_with_valid_crc(self):
        p=list(runner.EXPECTED)
        p[5]=loss_notice(sequence=5,dropped=1,good=99,bad=98,aborted=97)
        self.assertFalse(runner.assess_stream(witness(p))[0])

    def test_counter_snapshot_change_with_valid_crc(self):
        p=list(runner.EXPECTED)
        p[3]=frame(sequence=3,frame_crc=0xA5000004,error=True,
                   good=99,bad=22,aborted=33)
        self.assertFalse(runner.assess_stream(witness(p))[0])

    def test_notice_order_swap(self):
        p=list(runner.EXPECTED);p[5],p[6]=p[6],p[5]
        self.assertFalse(runner.assess_stream(witness(p))[0])

    def test_duplicate_index(self):
        self.assertFalse(runner.assess_stream(witness().replace('P124_PACKET 3 ',
                                                       'P124_PACKET 2 '))[0])

    def test_wrong_packet_size(self):
        self.assertFalse(runner.assess_stream(witness().replace(runner.EXPECTED[0].hex(),
                                              runner.EXPECTED[0].hex()+'ef'))[0])

    def test_fatal_and_skip_refused(self):
        for extra in ['FATAL: failed\n','P124_REAL_RTL_NOT_RUN\n',
                      'Traceback (most recent call last)\n']:
            with self.subTest(extra=extra):
                self.assertFalse(runner.assess_stream(witness()+extra)[0])

    def test_testbench_source_binds_depth_five_and_double_loss(self):
        source=runner.TB.read_text()
        self.assertIn('.FIFO_DEPTH(5)',source)
        self.assertIn('dropped_frame_events!==32\'d2',source)
        self.assertIn('P124_REAL_RTL_DEPTH5_LOSS_RACE_PASS',source)


class Gate(unittest.TestCase):
    def test_required_snapshot_covers_new_sources(self):
        filenames=gate.snapshot()
        for name in ['tests/rtl/a0_p124_depth5_loss_notice_race_tb.sv',
                     'tests/run_p124_depth5_loss_notice_race.py',
                     'tests/test_p124_oracle_and_gate.py',
                     'tools/a0_p124_rtl_qualification.py']:
            self.assertIn(name,filenames)

    def test_markers_both_required(self):
        self.assertEqual(gate.assess_new(0,gate.MARKER+'\n')[0],'FAIL')
        self.assertEqual(gate.assess_new(0,gate.ORACLE_MARKER+'\n')[0],'FAIL')

    def test_real_zero_exit_required(self):
        self.assertEqual(gate.assess_new(1,gate.MARKER+'\n'+gate.ORACLE_MARKER+'\n')[0],'FAIL')

    def test_not_run_is_not_pass(self):
        self.assertEqual(gate.assess_new(2,'NOT_RUN')[0],'NOT_RUN')

    def test_double_pass_marker_refused(self):
        self.assertEqual(gate.assess_new(0,gate.MARKER+'\n'+gate.MARKER+'\n'+
                                              gate.ORACLE_MARKER+'\n')[0],'FAIL')

    def test_source_evidence_missing_refused(self):
        self.assertFalse(gate.verify_inherited_p123({'status':'PASS','qualified':True},
                                                       0,Path('/no/such/p123'))[0])

    def test_fake_previous_gate_count_refused(self):
        data={'status':'PASS','qualified':True,'expected_gates':15,
              'execution_mode':'REAL_SUBPROCESS','p122_status':'PASS',
              'p123_status':'PASS','p122_evidence_valid':True,
              'sources_unchanged':True}
        self.assertFalse(gate.verify_inherited_p123(data,0,Path('/no/such'))[0])

    def test_no_fake_toolchain_success(self):
        with patch.object(runner.shutil,'which',return_value=None):
            self.assertEqual(runner.run(),2)

if __name__=='__main__':unittest.main()
