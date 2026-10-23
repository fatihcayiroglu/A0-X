"""P53 regression guards for single-shot P52 software acceptance, not RTL tests."""
import json
from pathlib import Path
import random
import contextlib
import io
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'sim'))
from a0_p52_capture_attestation import attest, reference, software_fixture, main
from a0_frame_telemetry_p48 import encode_frame

SCRIPT = json.loads((ROOT / 'examples/p44_triangle.json').read_text(encoding='utf-8'))


class P53SingleShotAttestationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = reference(SCRIPT)
        cls.valid = software_fixture(cls.reference)

    @staticmethod
    def frame(*, sequence=0, good=1, bad=0, aborted=0, dropped=0, crc=0):
        return encode_frame(sequence=sequence, error=False, frame_crc=crc,
                            good=good, bad=bad, aborted=aborted, dropped=dropped)

    def test_valid_single_frame_survives_fragmentation(self):
        for chunk_size in [1, 2, 3, 7, 16, 31, 32, 2048]:
            with self.subTest(chunk_size=chunk_size):
                self.assertEqual(attest(SCRIPT, self.valid, chunk_size=chunk_size)['status'], 'PASS')

    def test_second_valid_frame_cannot_turn_single_shot_into_pass(self):
        repeated = self.frame(sequence=1, good=2, crc=self.reference['frame_crc32'])
        for chunk_size in [1, 7, 32, 4096]:
            with self.subTest(chunk_size=chunk_size):
                verdict = attest(SCRIPT, self.valid + repeated, chunk_size=chunk_size)
                self.assertEqual(verdict['status'], 'FAIL')
                self.assertIn('unexpected_frame_telemetry_count', verdict['failure_reasons'])

    def test_single_frame_cannot_claim_multiple_good_frames(self):
        for good in [2, 5, 65537, 0xffffffff]:
            with self.subTest(good=good):
                capture = self.valid[:-32] + self.frame(good=good, crc=self.reference['frame_crc32'])
                verdict = attest(SCRIPT, capture)
                self.assertEqual(verdict['status'], 'FAIL')
                self.assertIn('frame_single_shot_counter_mismatch_0', verdict['failure_reasons'])

    def test_valid_second_frame_counter_replays_random_fragments_rejected(self):
        rng = random.Random(53053)
        for n in range(50):
            second = self.frame(sequence=1, good=2, crc=self.reference['frame_crc32'])
            split = rng.randrange(1, len(self.valid)+len(second))
            capture = self.valid+second
            # The decoder must reject a duplicate regardless of the stream chunk boundary.
            verdict = attest(SCRIPT, capture, chunk_size=split)
            self.assertEqual(verdict['status'], 'FAIL')
            self.assertIn('unexpected_frame_telemetry_count', verdict['failure_reasons'])

    def test_missing_frame_and_corrupted_crc_remain_fail_closed(self):
        self.assertEqual(attest(SCRIPT, self.valid[:-32])['status'], 'FAIL')
        broken = bytearray(self.valid)
        broken[-1] ^= 0x10
        self.assertEqual(attest(SCRIPT, bytes(broken))['status'], 'FAIL')

    def test_one_frame_with_correct_counter_and_crc_passes(self):
        s = self.valid[:-32] + self.frame(sequence=0,good=1,crc=self.reference['frame_crc32'])
        verdict = attest(SCRIPT, s)
        self.assertEqual(verdict['status'], 'PASS')
        self.assertEqual(verdict['observed']['frame_count'], 1)

    def test_cli_returns_nonzero_for_second_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            script_path = Path(tmp) / 'script.json'
            capture_path = Path(tmp) / 'capture.bin'
            script_path.write_text(json.dumps(SCRIPT), encoding='utf-8')
            capture_path.write_bytes(self.valid + self.frame(sequence=1,good=2,crc=self.reference['frame_crc32']))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(script_path),'--capture',str(capture_path)]), 1)

    def test_cli_returns_nonzero_for_forged_counter(self):
        with tempfile.TemporaryDirectory() as tmp:
            script_path = Path(tmp) / 'script.json'
            capture_path = Path(tmp) / 'capture.bin'
            script_path.write_text(json.dumps(SCRIPT), encoding='utf-8')
            capture_path.write_bytes(self.valid[:-32]+self.frame(good=5,crc=self.reference['frame_crc32']))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(script_path),'--capture',str(capture_path)]), 1)


if __name__ == '__main__':
    unittest.main()
