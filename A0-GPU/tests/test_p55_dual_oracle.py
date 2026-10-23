"""P55 independent graphics/oracle differential tests. SOFTWARE ONLY."""
import copy
import contextlib
import io
import tempfile
import json
from pathlib import Path
import random
import sys
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
sys.path.insert(0,str(ROOT/'tools'))
import a0_p55_dual_oracle as p55
import a0_p54_multiframe_attestation as p54
from a0_host_p44 import parse_script
from a0_independent_graphics_oracle_p55 import render_commands

SCRIPT=json.loads((ROOT/'examples'/'p54_two_frames.json').read_text())


def random_script(seed):
    rng=random.Random(seed)
    w,h = rng.randint(2,9),rng.randint(2,8)
    rows=[];tag=1
    for scene in range(rng.randint(2,4)):
        rows.append({'op':'CLEAR','tag':tag,'color':rng.randrange(1<<24)});tag+=1
        for _ in range(rng.randint(0,3)):
            rows.append({'op':'TRIANGLE','tag':tag,'color':rng.randrange(1<<24),
                         'vertices':[[rng.randint(-15,20),rng.randint(-15,20)] for _ in range(3)]});tag+=1
        rows.append({'op':'PRESENT','tag':tag});tag+=1
    return {'width':w,'height':h,'commands':rows}


class DualOracleP55(unittest.TestCase):
    def test_fixture_two_frames(self):
        self.assertEqual(p55.check_oracles(SCRIPT)['frame_count'],2)

    def test_independence_over_random_render_workloads(self):
        for seed in range(55):
            with self.subTest(seed=seed):
                self.assertEqual(p55.check_oracles(random_script(seed))['status'],'PASS')

    def test_winding_degenerate_clip_repeat_clears(self):
        for vertices in ([[0,0],[7,0],[0,7]],[[0,7],[7,0],[0,0]],
                         [[0,0],[3,3],[6,6]],[[-30000,-30000],[30000,-30000],[-30000,30000]]):
            s=copy.deepcopy(SCRIPT)
            s['commands'][1]['vertices']=vertices
            self.assertEqual(p55.check_oracles(s)['status'],'PASS')

    def test_both_banks_reused_without_clear(self):
        s={'width':3,'height':2,'commands':[
          {'op':'CLEAR','tag':1,'color':0x123456}, {'op':'PRESENT','tag':2},
          {'op':'CLEAR','tag':3,'color':0xaabbcc}, {'op':'PRESENT','tag':4},
          {'op':'PRESENT','tag':5}]}
        self.assertEqual(p55.check_oracles(s)['frame_count'],3)

    def test_invalid_state_rejected_by_direct_oracle(self):
        s={'width':2,'height':2,'commands':[{'op':'TRIANGLE','tag':1,'color':1,
             'vertices':[[0,0],[2,0],[0,2]]}]}
        with self.assertRaises(ValueError):render_commands(*parse_script(s))

    def test_detect_wrong_crc_even_if_capture_forged_to_match(self):
        ref=p54.reference(SCRIPT)
        corrupted=copy.deepcopy(ref)
        corrupted['frames'][0]['frame_crc32'] ^= 1
        # P54 can accept fake bytes consistent with its own corrupted oracle.
        from a0_p54_multiframe_attestation import synthetic_fixture
        capture=synthetic_fixture(corrupted)
        with patch.object(p54,'reference',return_value=corrupted):
            self.assertEqual(p54.attest(SCRIPT,capture)['status'],'PASS')
            with self.assertRaisesRegex(p55.OracleMismatch,'frame_crc32'):
                p55.attest(SCRIPT,capture)

    def test_detect_wrong_sha_reference(self):
        ref=p54.reference(SCRIPT)
        corrupted=copy.deepcopy(ref)
        corrupted['frames'][1]['rgb_sha256']='0'*64
        with patch.object(p54,'reference',return_value=corrupted):
            with self.assertRaisesRegex(p55.OracleMismatch,'rgb_sha256'):
                p55.check_oracles(SCRIPT)

    def test_reject_missing_or_extra_frames_and_byte_corruption(self):
        capture=p54.synthetic_fixture(p54.reference(SCRIPT))
        self.assertEqual(p55.attest(SCRIPT,capture)['status'],'PASS')
        self.assertEqual(p55.attest(SCRIPT,capture[:-32])['status'],'FAIL')
        self.assertEqual(p55.attest(SCRIPT,capture+capture[-32:])['status'],'FAIL')
        mut=bytearray(capture);mut[-1]^=1
        self.assertEqual(p55.attest(SCRIPT,bytes(mut))['status'],'FAIL')

    def test_reference_only_not_hardware(self):
        capture=p54.synthetic_fixture(p54.reference(SCRIPT))
        r=p55.attest(SCRIPT,capture)
        self.assertIn('NOT_RTL_OR_HARDWARE',r['evidence_level'])
        self.assertEqual(r['independent_oracle']['evidence_level'],'SOFTWARE_ONLY_NOT_RTL_OR_HARDWARE')

    def test_cli_reference_and_capture_rejection(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            script=p/'workload.json'; script.write_text(json.dumps(SCRIPT))
            report=p/'check.json'
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p55.main(['--script',str(script),'--report',str(report)]),0)
            ref=json.loads(report.read_text())
            self.assertEqual(ref['kind'],'P55_TWO_INDEPENDENT_SOFTWARE_GRAPHICS_ORACLES')
            capture=p/'capture.bin'; capture.write_bytes(p54.synthetic_fixture(p54.reference(SCRIPT)))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p55.main(['--script',str(script),'--capture',str(capture),'--report',str(report)]),0)
            self.assertEqual(json.loads(report.read_text())['status'],'PASS')
            capture.write_bytes(capture.read_bytes()[:-32])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(p55.main(['--script',str(script),'--capture',str(capture),'--report',str(report)]),1)

    def test_capture_constraints(self):
        with self.assertRaises(ValueError):
            p55.attest(SCRIPT,b'',chunk_size=0)
        with self.assertRaises(ValueError):
            p55.attest(SCRIPT,b'X' * (16 * 1024 * 1024 + 1))

    def test_reject_invalid_command(self):
        s=copy.deepcopy(SCRIPT)
        s['commands'][1]['vertices'][0][0]=40000
        with self.assertRaises(ValueError):p55.check_oracles(s)

if __name__=='__main__':unittest.main()
