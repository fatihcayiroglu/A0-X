"""P120 host plan binding negative and boundary tests (software-only)."""
import contextlib
import io
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest
import zlib

BASE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(BASE/'sim'))
sys.path.insert(0,str(BASE/'tools'))
from a0_p107_host_batch import compile_plan
from a0_host_protocol_p44 import Result, encode_result
from a0_frame_telemetry_p48 import encode_frame
from a0_p118_loss_notice import encode_loss_notice
from a0_p119_epoch_reconcile import audit_epoch
from a0_p120_planned_telemetry import PlannedTelemetryAudit, audit_planned_stream
from a0_p120_plan_audit import main

PLAN=json.loads((BASE/'examples/p107/session.json').read_text())


def fixture(*, dropped=0):
    s=compile_plan(PLAN)
    packets=[encode_result(Result(0,d.command.tag,12)) for d in s.draws]
    packets.append(encode_frame(sequence=0,error=False,frame_crc=s.expected_crcs[0],
                                good=1,bad=0,aborted=0,dropped=0))
    if dropped:
        packets.append(encode_loss_notice(sequence=2,dropped=1,good=2,bad=0,aborted=0))
    else:
        packets.append(encode_frame(sequence=1,error=False,frame_crc=s.expected_crcs[1],
                                    good=2,bad=0,aborted=0,dropped=0))
    return s, packets


def fix_crc(blob):
    b=bytearray(blob)
    b[-4:]=zlib.crc32(b[:-4]).to_bytes(4,'little')
    return bytes(b)


class TestP120(unittest.TestCase):
    def test_full_planned_capture(self):
        s,p=fixture()
        r=audit_planned_stream(s,b''.join(p),epoch='reset1',sent_wire=s.wire,final_dropped=0)
        self.assertEqual(r['status'],'FULL_SOFTWARE_CONSISTENCY')
        self.assertEqual((r['result_packets'],r['planned_frames']),(5,2))
        self.assertEqual(r['unverified_frame_indices'],[])
        self.assertFalse(r['physical_hardware_verified'])
        self.assertFalse(r['capture_source_authenticated'])
        self.assertFalse(r['sent_wire_physically_observed'])

    def test_captured_crc_forgery_old_auditor_accepts(self):
        s,p=fixture()
        tamper=bytearray(p[-1]);tamper[8:12]=(s.expected_crcs[1]^0x10).to_bytes(4,'little')
        p[-1]=fix_crc(tamper)
        # P119 checks stream integrity only, not independent image goldens.
        self.assertEqual(audit_epoch(b''.join(p),epoch='x',final_attempted=2,final_dropped=0,
                                     expected_result_tags=[d.command.tag for d in s.draws])['status'],
                         'SOFTWARE_STREAM_CONSISTENT')
        with self.assertRaisesRegex(ValueError,'golden CRC'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_partial_is_not_full(self):
        s,p=fixture(dropped=1)
        r=audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=1)
        self.assertEqual(r['status'],'PARTIAL_TELEMETRY_ONLY')
        self.assertEqual(r['unverified_frame_indices'],[1])
        self.assertFalse(r['full_image_sequence_proven_from_capture'])
        self.assertEqual(r['result_packets'],5)

    def test_lost_frame_without_notice_rejected(self):
        s,p=fixture(dropped=1)
        with self.assertRaises(ValueError):
            audit_planned_stream(s,b''.join(p[:-1]),epoch='x',sent_wire=s.wire,final_dropped=1)

    def test_lost_frame_without_declared_drop_rejected(self):
        s,p=fixture(dropped=1)
        with self.assertRaises(ValueError):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_unplanned_additional_frame_rejected(self):
        s,p=fixture()
        extra=encode_frame(sequence=2,error=False,frame_crc=12,good=3,bad=0,aborted=0,dropped=0)
        with self.assertRaisesRegex(ValueError,'unplanned frame'):
            audit_planned_stream(s,b''.join(p)+extra,epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_missing_last_result_rejected(self):
        s,p=fixture()
        with self.assertRaisesRegex(ValueError,'missing planned'):
            audit_planned_stream(s,b''.join(p[:4]+p[5:]),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_duplicate_command_rejected(self):
        s,p=fixture()
        with self.assertRaisesRegex(ValueError,'tag/status'):
            audit_planned_stream(s,p[0]+b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_swapped_command_tag_rejected(self):
        s,p=fixture();p[0],p[1]=p[1],p[0]
        with self.assertRaisesRegex(ValueError,'tag/status'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_error_command_rejected(self):
        s,p=fixture();p[0]=encode_result(Result(1,s.draws[0].command.tag,12))
        with self.assertRaisesRegex(ValueError,'tag/status'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_wrong_ordered_frame_rejected(self):
        s,p=fixture();p[-1],p[-2]=p[-2],p[-1]
        with self.assertRaisesRegex(ValueError,'golden CRC|discontinuity'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_corrupt_packet_crc(self):
        s,p=fixture();bad=bytearray(p[-1]);bad[9]^=0x10;p[-1]=bytes(bad)
        with self.assertRaisesRegex(ValueError,'crc'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_unplanned_golden_mismatch_on_first_frame(self):
        s,p=fixture();bad=bytearray(p[-2]);bad[8:12]=(99).to_bytes(4,'little');p[-2]=fix_crc(bad)
        with self.assertRaisesRegex(ValueError,'golden CRC'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_frame_error_flag(self):
        s,p=fixture();bad=bytearray(p[-1]);bad[5]=1;p[-1]=fix_crc(bad)
        with self.assertRaisesRegex(ValueError,'golden CRC/error'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_frame_good_mismatch(self):
        s,p=fixture();bad=bytearray(p[-1]);bad[12:16]=(77).to_bytes(4,'little');p[-1]=fix_crc(bad)
        with self.assertRaisesRegex(ValueError,'progress/error counters'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_frame_bad_nonzero(self):
        s,p=fixture();bad=bytearray(p[-1]);bad[16:20]=(1).to_bytes(4,'little');p[-1]=fix_crc(bad)
        with self.assertRaisesRegex(ValueError,'progress/error counters'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_notice_bad_counter(self):
        s,p=fixture(dropped=1);bad=bytearray(p[-1]);bad[16:20]=(1).to_bytes(4,'little');p[-1]=fix_crc(bad)
        with self.assertRaisesRegex(ValueError,'bad/aborted'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=1)

    def test_forged_sent_wire_rejected(self):
        s,p=fixture()
        with self.assertRaisesRegex(ValueError,'sent-wire'):
            audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire+b'\0',final_dropped=0)

    def test_wrong_compiled_session_rejected(self):
        s,p=fixture()
        with self.assertRaisesRegex(ValueError,'CompiledSession'):
            audit_planned_stream(None,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_bad_inputs_rejected(self):
        s,p=fixture()
        for chunk in (0,-1,True,65537,1.5):
            with self.assertRaises(ValueError):
                audit_planned_stream(s,b''.join(p),epoch='x',sent_wire=s.wire,final_dropped=0,chunk_size=chunk)
        with self.assertRaises(ValueError):
            audit_planned_stream(s,bytearray(b''.join(p)),epoch='x',sent_wire=s.wire,final_dropped=0)

    def test_random_chunk_boundaries_identical(self):
        s,p=fixture();blob=b''.join(p)
        expected=audit_planned_stream(s,blob,epoch='x',sent_wire=s.wire,final_dropped=0)
        for seed in range(25):
            rng=random.Random(seed);a=PlannedTelemetryAudit(s,epoch='x',sent_wire=s.wire);i=0
            while i<len(blob):
                k=rng.randint(1,25);a.feed(blob[i:i+k]);i+=k
            self.assertEqual(a.finalize(final_dropped=0),expected)

    def test_poisoned_after_wrong_packet(self):
        s,p=fixture();audit=PlannedTelemetryAudit(s,epoch='x',sent_wire=s.wire)
        with self.assertRaises(ValueError):audit.feed(b'BAD!')
        with self.assertRaisesRegex(ValueError,'invalidated'):audit.feed(b'')

    def test_no_linear_result_tag_storage(self):
        s,p=fixture();a=PlannedTelemetryAudit(s,epoch='x',sent_wire=s.wire)
        a.feed(b''.join(p))
        self.assertEqual(len(a.result_tags),0)
        self.assertEqual(a._verified_results,5)
        self.assertEqual(len(a._buffer),0)

    def test_cli_full(self):
        s,p=fixture()
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);plan=d/'plan.json';plan.write_text(json.dumps(PLAN))
            capture=d/'capture.bin';capture.write_bytes(b''.join(p))
            wire=d/'wire.bin';wire.write_bytes(s.wire)
            out=d/'audit.json'
            with contextlib.redirect_stdout(io.StringIO()):
                code=main(['--plan',str(plan),'--capture',str(capture),'--sent-wire',str(wire),
                           '--epoch','epoch','--final-dropped','0','--output',str(out)])
            self.assertEqual(code,0)
            self.assertEqual(json.loads(out.read_text())['status'],'FULL_SOFTWARE_CONSISTENCY')

    def test_cli_partial_is_distinct_nonzero(self):
        s,p=fixture(dropped=1)
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);plan=d/'plan.json';plan.write_text(json.dumps(PLAN))
            capture=d/'capture.bin';capture.write_bytes(b''.join(p));wire=d/'wire.bin';wire.write_bytes(s.wire)
            out=d/'out.json'
            with contextlib.redirect_stdout(io.StringIO()):
                code=main(['--plan',str(plan),'--capture',str(capture),'--sent-wire',str(wire),
                           '--epoch','epoch','--final-dropped','1','--output',str(out)])
            self.assertEqual(code,3)
            self.assertEqual(json.loads(out.read_text())['status'],'PARTIAL_TELEMETRY_ONLY')

    def test_cli_rejects_overwrite(self):
        s,p=fixture()
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);plan=d/'plan.json';plan.write_text(json.dumps(PLAN));capture=d/'capture.bin';capture.write_bytes(b''.join(p));wire=d/'wire.bin';wire.write_bytes(s.wire)
            with contextlib.redirect_stderr(io.StringIO()):
                code=main(['--plan',str(plan),'--capture',str(capture),'--sent-wire',str(wire),
                           '--epoch','epoch','--final-dropped','0','--output',str(capture)])
            self.assertEqual(code,1)
            self.assertEqual(capture.read_bytes(),b''.join(p))

    def test_cli_rejects_bad_capture_no_report(self):
        s,p=fixture()
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);plan=d/'plan.json';plan.write_text(json.dumps(PLAN));capture=d/'capture.bin';capture.write_bytes(b'BAD!');wire=d/'wire.bin';wire.write_bytes(s.wire);out=d/'out.json'
            with contextlib.redirect_stderr(io.StringIO()):
                code=main(['--plan',str(plan),'--capture',str(capture),'--sent-wire',str(wire),
                           '--epoch','epoch','--final-dropped','0','--output',str(out)])
            self.assertEqual(code,1)
            self.assertFalse(out.exists())

if __name__=='__main__':unittest.main()
