"""P52 comparison tests on independently supplied/synthetic bytes, NOT real RTL."""
import json
import contextlib
import io
from pathlib import Path
import random
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'sim'))
from a0_p52_capture_attestation import attest, reference, software_fixture, main
from a0_host_result_wire_p46 import serialize_result
from a0_frame_telemetry_p48 import encode_frame

SCRIPT={'width':9,'height':5,'commands':[
    {'op':'CLEAR','tag':1,'color':'#102030'},
    {'op':'TRIANGLE','tag':2,'color':'#ffee11','vertices':[[1,1],[7,1],[3,4]]},
    {'op':'PRESENT','tag':3}
]}

class CaptureAttestationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ref=reference(SCRIPT)
        cls.capture=software_fixture(cls.ref)

    def test_correct_trace(self):
        r=attest(SCRIPT,self.capture)
        self.assertEqual(r['status'],'PASS')
        self.assertEqual(r['observed']['completion_count'],3)
        self.assertEqual(r['observed']['frame_count'],1)
        self.assertEqual(r['evidence_level'],'SOFTWARE_REFERENCE_VS_SUPPLIED_BYTES_NOT_RTL_OR_HARDWARE')

    def test_arbitrary_fragmentation(self):
        for n in [1,2,3,4,7,16,31,32,63,4096]:
            self.assertEqual(attest(SCRIPT,self.capture,chunk_size=n)['status'],'PASS')

    def test_frame_crc_bytes_match_independent_formula(self):
        import zlib
        from a0_host_p44 import parse_script
        from a0_host_runtime_p44 import P44SoftwareDevice
        from a0_host_protocol_p44 import encode_command
        w,h,cmds=parse_script(SCRIPT)
        d=P44SoftwareDevice(w,h)
        for _,c in cmds:d.receive(encode_command(c))
        rgb=d.visible_rgb()
        bgr=b''.join(rgb[i:i+3][::-1] for i in range(0,len(rgb),3))
        self.assertEqual(self.ref['frame_crc32'],zlib.crc32(bgr))

    def test_mutate_crc_fails(self):
        broken=bytearray(self.capture);broken[-1]^=1
        self.assertIn('invalid_or_truncated_host_stream',attest(SCRIPT,bytes(broken))['failure_reasons'])

    def test_unexpected_tag_fails(self):
        s=serialize_result(99,False,123)+self.capture[16:]
        self.assertIn('completion_tag_or_order_mismatch_0',attest(SCRIPT,s)['failure_reasons'])

    def test_duplicate_completion_fails(self):
        s=self.capture[:16]+self.capture
        self.assertIn('missing_or_duplicate_command_completions',attest(SCRIPT,s)['failure_reasons'])

    def test_missing_completion_fails(self):
        s=self.capture[16:]
        self.assertIn('missing_or_duplicate_command_completions',attest(SCRIPT,s)['failure_reasons'])

    def test_result_after_frame_rejected(self):
        s=self.capture[:-32]+self.capture[-32:]+serialize_result(4,False,123)
        self.assertIn('result_received_after_frame_telemetry',attest(SCRIPT,s)['failure_reasons'])

    def test_telemetry_before_completion_rejected(self):
        s=self.capture[-32:]+self.capture[:-32]
        self.assertIn('frame_before_all_command_completions',attest(SCRIPT,s)['failure_reasons'])

    def test_valid_but_wrong_image_crc_rejected(self):
        s=self.capture[:-32]+encode_frame(sequence=0,error=False,frame_crc=self.ref['frame_crc32']^1,good=1,bad=0,aborted=0,dropped=0)
        self.assertIn('frame_pixel_crc_mismatch_0',attest(SCRIPT,s)['failure_reasons'])

    def test_explicit_bad_frame_rejected(self):
        s=self.capture[:-32]+encode_frame(sequence=0,error=True,frame_crc=self.ref['frame_crc32'],good=0,bad=1,aborted=0,dropped=0)
        self.assertIn('frame_error_or_abort_0',attest(SCRIPT,s)['failure_reasons'])

    def test_zero_good_frames_rejected(self):
        s=self.capture[:-32]+encode_frame(sequence=0,error=False,frame_crc=self.ref['frame_crc32'],good=0,bad=0,aborted=0,dropped=0)
        self.assertIn('frame_error_or_abort_0',attest(SCRIPT,s)['failure_reasons'])

    def test_missing_frame_fails(self):
        self.assertIn('no_complete_frame_telemetry',attest(SCRIPT,self.capture[:-32])['failure_reasons'])

    def test_sequence_gap_and_dropped_counter_rejected(self):
        extra=encode_frame(sequence=2,error=False,frame_crc=self.ref['frame_crc32'],good=2,bad=0,aborted=0,dropped=1)
        self.assertIn('frame_sequence_or_drop_ambiguity',attest(SCRIPT,self.capture+extra)['failure_reasons'])

    def test_wrong_script_detected(self):
        other=json.loads(json.dumps(SCRIPT));other['commands'][0]['color']='#000000'
        self.assertIn('frame_pixel_crc_mismatch_0',attest(other,self.capture)['failure_reasons'])

    def test_not_single_shot_refused(self):
        for bad in ([{'op':'CLEAR','tag':10,'color':0}], SCRIPT['commands']+[{'op':'PRESENT','tag':4}]):
            case={**SCRIPT,'commands':bad}
            with self.assertRaises(ValueError):reference(case)

    def test_nonbytes_and_large_capture_refused(self):
        for val in ('data',bytearray(self.capture),b'A'* (16*1024*1024+1)):
            with self.assertRaises(ValueError):attest(SCRIPT,val)

    def test_corruption_noise_does_not_pass(self):
        rng=random.Random(52052)
        for _ in range(80):
            x=bytearray(self.capture)
            index=rng.randrange(len(x))
            x[index]^=1 << rng.randrange(8)
            self.assertEqual(attest(SCRIPT,bytes(x))['status'],'FAIL')

    def test_cli_synthetic_marked_and_round_trip(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);s=p/'script.json';f=p/'fake.bin';r=p/'report.json';s.write_text(json.dumps(SCRIPT))
            self.assertEqual(main(['--script',str(s),'--make-software-fixture',str(f),'--report',str(r)]),0)
            self.assertEqual(json.loads(r.read_text())['kind'],'A0_P52_SYNTHETIC_FIXTURE')
            self.assertEqual(main(['--script',str(s),'--capture',str(f),'--report',str(r)]),0)
            self.assertEqual(json.loads(r.read_text())['status'],'PASS')

    def test_cli_wrong_image_returns_failure(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);s=p/'script.json';f=p/'fake.bin';s.write_text(json.dumps({**SCRIPT,'commands':[{'op':'CLEAR','tag':1,'color':0},*SCRIPT['commands'][1:]]}))
            f.write_bytes(self.capture)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(s),'--capture',str(f)]),1)

if __name__=='__main__':unittest.main()
