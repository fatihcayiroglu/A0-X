"""P54 multi-PRESENT external-byte acceptance, software only; not an HDL test."""
import contextlib
import io
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'sim'))
from a0_p54_multiframe_attestation import reference,attest,synthetic_fixture,main
from a0_frame_telemetry_p48 import encode_frame
from a0_host_result_wire_p46 import serialize_result

SCRIPT=json.loads((ROOT/'examples'/'p54_two_frames.json').read_text())

class P54MultiFrameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ref=reference(SCRIPT)
        cls.capture=synthetic_fixture(cls.ref)
        cls.n=len(cls.ref['results'])
        cls.f=len(cls.ref['frames'])

    def frame(self, i, *, sequence=None, good=None, crc=None, error=False, bad=0, aborted=0,dropped=0):
        return encode_frame(sequence=i if sequence is None else sequence,error=error,
                            frame_crc=self.ref['frames'][i]['frame_crc32'] if crc is None else crc,
                            good=i+1 if good is None else good,bad=bad,aborted=aborted,dropped=dropped)

    def test_two_distinct_frames_are_expected(self):
        self.assertEqual((self.n,self.f),(6,2))
        self.assertNotEqual(self.ref['frames'][0]['frame_crc32'],self.ref['frames'][1]['frame_crc32'])

    def test_valid_fragmentation(self):
        for n in (1,2,3,7,16,31,32,41,4096):
            with self.subTest(n=n):
                self.assertEqual(attest(SCRIPT,self.capture,chunk_size=n)['status'],'PASS')

    def test_random_fragmentation(self):
        rnd=random.Random(540054)
        for _ in range(50):
            n=rnd.randrange(1,100)
            self.assertEqual(attest(SCRIPT,self.capture,chunk_size=n)['status'],'PASS')

    def test_second_frame_missing(self):
        self.assertIn('frame_count_mismatch',attest(SCRIPT,self.capture[:-32])['failures'])

    def test_second_frame_duplicated(self):
        self.assertIn('frame_count_mismatch',attest(SCRIPT,self.capture+self.capture[-32:])['failures'])

    def test_wrong_second_crc(self):
        c=self.capture[:-32]+self.frame(1,crc=self.ref['frames'][1]['frame_crc32']^1)
        self.assertIn('frame_crc_mismatch_1',attest(SCRIPT,c)['failures'])

    def test_swapped_frame_crc(self):
        first=self.frame(0,crc=self.ref['frames'][1]['frame_crc32'])
        second=self.frame(1,crc=self.ref['frames'][0]['frame_crc32'])
        c=self.capture[:48]+first+self.capture[80:-32]+second
        self.assertEqual(len(c),len(self.capture))
        self.assertIn('frame_crc_mismatch_0',attest(SCRIPT,c)['failures'])

    def test_wrong_sequence_second_frame(self):
        c=self.capture[:-32]+self.frame(1,sequence=0)
        self.assertIn('frame_sequence_mismatch_1',attest(SCRIPT,c)['failures'])

    def test_counter_jump_second_frame(self):
        c=self.capture[:-32]+self.frame(1,good=5)
        self.assertIn('frame_good_counter_mismatch_1',attest(SCRIPT,c)['failures'])

    def test_error_and_drop(self):
        for kwargs in ({'error':True},{'bad':1},{'aborted':1},{'dropped':1}):
            with self.subTest(kwargs=kwargs):
                c=self.capture[:-32]+self.frame(1,**kwargs)
                self.assertIn('frame_error_or_loss_1',attest(SCRIPT,c)['failures'])

    def test_wrong_result_tag(self):
        c=serialize_result(655,False,123)+self.capture[16:]
        self.assertIn('completion_tag_mismatch_0',attest(SCRIPT,c)['failures'])

    def test_result_error(self):
        c=serialize_result(101,True,123)+self.capture[16:]
        self.assertIn('completion_error_0',attest(SCRIPT,c)['failures'])

    def test_frame_before_corresponding_present_result(self):
        c=self.frame(0)+self.capture
        self.assertIn('frame_before_present_completion_0',attest(SCRIPT,c)['failures'])

    def test_corrupted_payload_rejected(self):
        c=bytearray(self.capture);c[-2]^=0x80
        self.assertIn('invalid_or_truncated_capture',attest(SCRIPT,bytes(c))['failures'])

    def test_extra_noise_rejected(self):
        self.assertIn('invalid_or_truncated_capture',attest(SCRIPT,b'X'+self.capture)['failures'])

    def test_reject_single_shot_and_nonfinal_present(self):
        with self.assertRaises(ValueError):
            reference({**SCRIPT,'commands':SCRIPT['commands'][:3]})
        with self.assertRaises(ValueError):
            reference({**SCRIPT,'commands':SCRIPT['commands'][:-1]})

    def test_reject_nonbytes_and_bad_chunk(self):
        with self.assertRaises(ValueError):attest(SCRIPT,bytearray(self.capture))
        for value in (0,False,1.5,2**25):
            with self.assertRaises(ValueError):attest(SCRIPT,self.capture,chunk_size=value)

    def test_cli_and_explicit_software_origin(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);script=p/'script.json';cap=p/'fixture.bin';report=p/'receipt.json'
            script.write_text(json.dumps(SCRIPT))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(script),'--make-synthetic-fixture',str(cap),'--report',str(report)]),0)
            self.assertEqual(json.loads(report.read_text())['evidence_level'],'SOFTWARE_ONLY_NOT_DEVICE_EVIDENCE')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(script),'--capture',str(cap),'--report',str(report)]),0)
            self.assertEqual(json.loads(report.read_text())['status'],'PASS')
            cap.write_bytes(cap.read_bytes()[:-32])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(script),'--capture',str(cap)]),1)

if __name__=='__main__':unittest.main()
