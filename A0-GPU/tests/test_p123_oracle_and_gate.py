"""P123 host oracle and 16-gate fail-closed control regression tests.

Pure tests are not substitutes for executing Icarus RTL simulations.
"""
from __future__ import annotations
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
import run_p123_depth3_reset_stream as runner
spec=importlib.util.spec_from_file_location('a0_p123_gate',ROOT/'tools/a0_p123_rtl_qualification.py')
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def witness(packets=None, *,pass_marker=True,discard=True):
    pkts=runner.EXPECTED if packets is None else packets
    out='\n'.join(f'P123_PACKET {i} {data.hex()}' for i,data in enumerate(pkts))+'\n'
    if discard:out+='P123_PARTIAL_DISCARDED 7\n'
    if pass_marker:out+=runner.MARKER+'\n'
    return out


class PacketOracle(unittest.TestCase):
    def test_expected_nine_packets(self):
        self.assertEqual(len(runner.EXPECTED),9)
        self.assertTrue(runner.assess_stream(witness())[0])

    def test_each_valid_packet_is_independently_decodable(self):
        from a0_p122_packet_oracle import decode
        rows=[decode(b) for b in runner.EXPECTED]
        self.assertEqual([r['type'] for r in rows],['frame']*7+['loss','frame'])
        self.assertEqual([r['sequence'] for r in rows],list(range(7))+[8,0])
        self.assertEqual(rows[7]['dropped'],1)
        self.assertEqual(rows[8]['frame_crc'],0xd000000a)

    def test_missing_packet_refused(self):
        self.assertFalse(runner.assess_stream(witness(runner.EXPECTED[:-1]))[0])

    def test_extra_packet_refused(self):
        self.assertFalse(runner.assess_stream(witness(runner.EXPECTED+[runner.EXPECTED[0]]))[0])

    def test_crc_corruption_refused(self):
        packets=list(runner.EXPECTED)
        altered=bytearray(packets[5]);altered[7]^=1;packets[5]=bytes(altered)
        self.assertFalse(runner.assess_stream(witness(packets))[0])

    def test_wrong_payload_with_valid_crc_refused(self):
        from a0_p122_packet_oracle import frame
        packets=list(runner.EXPECTED)
        packets[3]=frame(sequence=3,frame_crc=0xdeadbeef)
        ok,reason=runner.assess_stream(witness(packets))
        self.assertFalse(ok)
        self.assertIn('differs',reason)

    def test_duplicate_marker_refused(self):
        self.assertFalse(runner.assess_stream(witness()+runner.MARKER+'\n')[0])

    def test_missing_partial_packet_discard_refused(self):
        self.assertFalse(runner.assess_stream(witness(discard=False))[0])

    def test_duplicate_partial_packet_discard_refused(self):
        self.assertFalse(runner.assess_stream(witness()+'P123_PARTIAL_DISCARDED 7\n')[0])

    def test_reordered_packet_refused(self):
        packets=list(runner.EXPECTED)
        packets[3],packets[4]=packets[4],packets[3]
        self.assertFalse(runner.assess_stream(witness(packets))[0])

    def test_duplicate_packet_index_refused(self):
        self.assertFalse(runner.assess_stream(witness().replace('P123_PACKET 1 ',
                                                 'P123_PACKET 0 '))[0])

    def test_uppercase_hex_refused(self):
        text=witness()
        self.assertFalse(runner.assess_stream(text.replace(runner.EXPECTED[0].hex(),
                                                           runner.EXPECTED[0].hex().upper()))[0])

    def test_unexpected_diagnostic_refused(self):
        self.assertFalse(runner.assess_stream(witness()+'FATAL: BAD\n')[0])

    def test_oversize_packet_refused(self):
        self.assertFalse(runner.assess_stream(witness().replace(runner.EXPECTED[0].hex(),
                                                           runner.EXPECTED[0].hex()+'aa'))[0])

    def test_source_has_depth3_and_reset(self):
        tb=gate.TB.read_text()
        self.assertIn('.FIFO_DEPTH(3)',tb)
        self.assertIn('rst_n=0',tb)
        self.assertIn('P123_REAL_RTL_DEPTH3_RESET_PASS',tb)


class GateController(unittest.TestCase):
    def test_sixteen_total(self):
        self.assertEqual(gate.load_p122().load_p121().GATES.__len__()+2,16)

    def test_sources_exist_in_snapshot(self):
        data=gate.source_snapshot(gate.ROOT)
        self.assertIn('tests/rtl/a0_p123_depth3_reset_stream_tb.sv',data)
        self.assertIn('tests/run_p123_depth3_reset_stream.py',data)
        self.assertIn('rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv',data)
        self.assertIn('tools/a0_p123_rtl_qualification.py',data)

    def test_new_pass_marker(self):
        ok,_=gate.assess_new(0,gate.MARKER+'\nP123 INDEPENDENT PACKET ORACLE: nine valid ordered packets\n')
        self.assertEqual(ok,'PASS')

    def test_fake_success_without_oracle_refused(self):
        self.assertEqual(gate.assess_new(0,gate.MARKER+'\n')[0],'FAIL')

    def test_wrong_exit_refused(self):
        self.assertEqual(gate.assess_new(1,gate.MARKER+'\n')[0],'FAIL')

    def test_missing_iverilog_is_not_run(self):
        self.assertEqual(gate.assess_new(2,'NOT_RUN')[0],'NOT_RUN')

    def test_duplicate_marker_refused(self):
        self.assertEqual(gate.assess_new(0,gate.MARKER+'\n'+gate.MARKER+'\n')[0],'FAIL')

    def test_missing_inherited_evidence_refused(self):
        ok,_=gate.verify_inherited_p122({'qualified':True,'status':'PASS'},0,Path('/no/evidence'))
        self.assertFalse(ok)

    def test_mocked_inherited_evidence_refused(self):
        info={'qualified':True,'status':'PASS','execution_mode':'MOCKED_UNIT_TEST',
              'expected_gates':15}
        self.assertFalse(gate.verify_inherited_p122(info,0,Path('/no/evidence'))[0])

    def test_inherited_failure_refused(self):
        self.assertFalse(gate.verify_inherited_p122({'status':'PASS','qualified':True},1,
                                                      Path('/no/evidence'))[0])

    def test_new_missing_toolchain_runnable(self):
        import shutil
        if not (shutil.which('iverilog') and shutil.which('vvp')):
            self.assertEqual(runner.run(),2)

if __name__=='__main__':unittest.main()
