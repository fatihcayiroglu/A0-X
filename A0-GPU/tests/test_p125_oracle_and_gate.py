"""P125 host/software-only oracle and evidence security unit tests (not HDL)."""
from __future__ import annotations
import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
sys.path.insert(0,str(ROOT/'tools'))
import run_p125_depth7_ring_reset as runner
import a0_p125_rtl_qualification as gate
from a0_p122_packet_oracle import decode,frame,loss_notice


def synthetic(packets=None,prefix=None,marker=True,witness=True):
    packets=runner.EXPECTED if packets is None else packets
    prefix=runner.ABORTED[:9] if prefix is None else prefix
    lines=[f'P125_PACKET {i} {p.hex()}' for i,p in enumerate(packets)]
    lines.append('P125_DISCARDED_PREFIX '+prefix.hex())
    if witness:lines.append(runner.WITNESS)
    if marker:lines.append(runner.PASS)
    return '\n'.join(lines)+'\n'


class WireOracle(unittest.TestCase):
    def test_full_expected_stream_and_post_reset_epoch(self):
        yes,reason=runner.assess_stream(synthetic())
        self.assertTrue(yes,reason)
        rows=[decode(x) for x in runner.EXPECTED]
        self.assertEqual(len(rows),10)
        self.assertEqual([r['type'] for r in rows],['frame']*7+['loss']*2+['frame'])
        self.assertEqual([r['sequence'] for r in rows],[0,1,2,3,4,5,6,8,9,0])
        self.assertEqual([r['dropped'] for r in rows[7:]],[1,2,0])
        self.assertEqual([r['good'] for r in rows],[10]*7+[40,40,4])

    def test_before_reset_prefix_is_exactly_nine_bytes(self):
        self.assertEqual(len(runner.ABORTED[:9]),9)
        self.assertEqual(decode(runner.ABORTED)['sequence'],9)
        self.assertFalse(runner.assess_stream(synthetic(prefix=runner.ABORTED[1:10]))[0])

    def test_refuse_missing_prefix(self):
        self.assertFalse(runner.assess_stream(synthetic().replace(
            'P125_DISCARDED_PREFIX '+runner.ABORTED[:9].hex()+'\n',''))[0])

    def test_refuse_duplicate_prefix(self):
        text=synthetic()
        self.assertFalse(runner.assess_stream(text+'P125_DISCARDED_PREFIX '+runner.ABORTED[:9].hex()+'\n')[0])

    def test_refuse_short_prefix(self):
        self.assertFalse(runner.assess_stream(synthetic(prefix=runner.ABORTED[:8]))[0])

    def test_refuse_extra_or_missing_packet(self):
        self.assertFalse(runner.assess_stream(synthetic(runner.EXPECTED[:-1]))[0])
        self.assertFalse(runner.assess_stream(synthetic(runner.EXPECTED+[runner.EXPECTED[0]]))[0])

    def test_refuse_duplicate_packet_index(self):
        text=synthetic().replace('P125_PACKET 5 ','P125_PACKET 4 ')
        self.assertFalse(runner.assess_stream(text)[0])

    def test_refuse_header_corruption(self):
        data=list(runner.EXPECTED);bad=bytearray(data[1]);bad[0]^=1;data[1]=bytes(bad)
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_crc_corruption(self):
        data=list(runner.EXPECTED);bad=bytearray(data[7]);bad[18]^=1;data[7]=bytes(bad)
        ok,reason=runner.assess_stream(synthetic(data))
        self.assertFalse(ok)
        self.assertIn('CRC32',reason)

    def test_refuse_loss_drop_with_valid_crc(self):
        data=list(runner.EXPECTED)
        data[8]=loss_notice(sequence=9,dropped=1,good=40,bad=50,aborted=60)
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_notice_sequence_with_valid_crc(self):
        data=list(runner.EXPECTED)
        data[7]=loss_notice(sequence=7,dropped=1,good=40,bad=50,aborted=60)
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_frame_snapshot_change_with_valid_crc(self):
        data=list(runner.EXPECTED)
        data[2]=frame(sequence=2,frame_crc=0xC4000003,error=False,
                      good=40,bad=20,aborted=30)
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_lost_reset_epoch(self):
        data=list(runner.EXPECTED)
        data[9]=frame(sequence=10,frame_crc=0xD600000B,error=False,
                      good=4,bad=5,aborted=6,dropped=2)
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_swapped_notices(self):
        data=list(runner.EXPECTED);data[7],data[8]=data[8],data[7]
        self.assertFalse(runner.assess_stream(synthetic(data))[0])

    def test_refuse_missing_or_duplicate_witnesses(self):
        self.assertFalse(runner.assess_stream(synthetic(marker=False))[0])
        self.assertFalse(runner.assess_stream(synthetic(witness=False))[0])
        self.assertFalse(runner.assess_stream(synthetic()+runner.PASS+'\n')[0])
        self.assertFalse(runner.assess_stream(synthetic()+runner.WITNESS+'\n')[0])

    def test_refuse_error_diagnostics(self):
        for s in ('FATAL: unexpected\n','NOT_RUN\n','Traceback (most recent call last)\n'):
            with self.subTest(s=s):
                self.assertFalse(runner.assess_stream(synthetic()+s)[0])

    def test_reference_fifo_expected_scenario_is_consistent(self):
        # Software behavioral model corroborates our *expected bytes*, not RTL.
        sys.path.insert(0,str(ROOT/'sim'))
        from a0_p118_loss_notice import LossTelemetryFifoSpec
        model=LossTelemetryFifoSpec(depth=7)
        captured=bytearray()
        def feed(crc,err=False,good=10,bad=20,aborted=30):
            return model.tick(frame_valid=True,frame_crc=crc,error=err,
                              good=good,bad=bad,aborted=aborted)
        def consume(count):
            for _ in range(count):
                step=model.tick(tx_ready=True,good=40,bad=50,aborted=60)
                self.assertTrue(step.emitted)
                captured.append(step.byte)
        for i in range(7):
            self.assertTrue(feed(0xC4000001+i,bool(i%2)).frame_accepted)
        self.assertTrue(feed(0xB4000001,True).dropped)
        self.assertEqual(len(model.queue),7)
        self.assertEqual(model.dropped,1)
        consume(32)
        self.assertTrue(feed(0xB4000002,False,40,50,60).dropped)
        consume(32)
        consume(224)
        self.assertEqual(bytes(captured),b''.join(runner.EXPECTED[:9]))
        self.assertFalse(model.queue)
        self.assertEqual(model.dropped,2)
        self.assertTrue(feed(0xC600000A,True,100,200,300).frame_accepted)
        consume(9)
        self.assertEqual(bytes(captured[-9:]),runner.ABORTED[:9])
        model.tick(rst_n=False)
        self.assertEqual(model.sequence,0)
        self.assertEqual(model.dropped,0)
        self.assertTrue(feed(0xD600000B,False,4,5,6).frame_accepted)
        consume(32)
        self.assertEqual(bytes(captured[-32:]),runner.NEW)

    def test_rtl_tb_does_not_use_verilog_wire_keyword_as_identifier(self):
        # Catches a source-level syntax mistake even when Icarus is unavailable.
        source=runner.TB.read_text(encoding='utf8')
        self.assertNotIn('logic [7:0] wire[',source)
        self.assertIn('logic [7:0] wire_bytes[',source)

    def test_expected_rtl_depth_and_reset(self):
        source=runner.TB.read_text(encoding='utf8')
        self.assertIn('.FIFO_DEPTH(7)',source)
        self.assertIn('drain(9)',source)
        self.assertIn('rst_n=0',source)
        self.assertIn(runner.PASS,source)


class FailClosedGate(unittest.TestCase):
    def test_snapshot_includes_p125_sources(self):
        snap=gate.snapshot()
        for rel in ('tests/rtl/a0_p125_depth7_ring_reset_tb.sv',
                    'tests/run_p125_depth7_ring_reset.py',
                    'tests/test_p125_oracle_and_gate.py',
                    'tools/a0_p125_rtl_qualification.py'):
            self.assertIn(rel,snap)

    def test_zero_and_two_distinct(self):
        self.assertEqual(gate.assess_new(2,'NOT_RUN')[0],'NOT_RUN')
        self.assertEqual(gate.assess_new(1,gate.PASS+'\n'+gate.ORACLE+'\n')[0],'FAIL')
        self.assertEqual(gate.assess_new(0,gate.PASS+'\n'+gate.ORACLE+'\n')[0],'PASS')

    def test_simulator_and_oracle_markers_both_needed(self):
        self.assertEqual(gate.assess_new(0,gate.PASS+'\n')[0],'FAIL')
        self.assertEqual(gate.assess_new(0,gate.ORACLE+'\n')[0],'FAIL')

    def test_duplicate_evidence_marker_refused(self):
        x=gate.PASS+'\n'+gate.ORACLE+'\n'
        self.assertEqual(gate.assess_new(0,x+gate.PASS+'\n')[0],'FAIL')
        self.assertEqual(gate.assess_new(0,x+gate.ORACLE+'\n')[0],'FAIL')

    def test_missing_previous_evidence_refused(self):
        self.assertFalse(gate.inherited_valid({'status':'PASS','qualified':True},0,
                                               Path('/nonexistent-p125'))[0])

    def test_fake_count_refused(self):
        data={'status':'PASS','qualified':True,'execution_mode':'REAL_SUBPROCESS',
              'expected_gates':16,'p123_status':'PASS','p124_status':'PASS',
              'p123_evidence_valid':True,'sources_unchanged':True}
        self.assertFalse(gate.inherited_valid(data,0,Path('/nonexistent-p125'))[0])

    def test_missing_toolchain_is_not_pass(self):
        with patch.object(runner.shutil,'which',return_value=None):
            self.assertEqual(runner.run(),2)

if __name__=='__main__':unittest.main()
