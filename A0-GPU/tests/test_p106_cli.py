"""P106 host utility tests, including invalid external JSON and CRC."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CLI=ROOT/'tools'/'a0_host_triangle_p106.py'
DEMO=ROOT/'examples'/'p106'/'triangle.json'

class CLI106(unittest.TestCase):
    def test_sample_build_and_inspect(self):
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'packet.bin'
            p=subprocess.run([sys.executable,str(CLI),'encode','--spec',str(DEMO),
                              '--output',str(f)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual(len(f.read_bytes()),56)
            p=subprocess.run([sys.executable,str(CLI),'inspect','--input',str(f)],
                             capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr)
            data=json.loads(p.stdout)
            self.assertEqual(data['scissor'],[1,1,2,2])
            self.assertEqual(data['tag'],2)

    def test_malformed_json_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as t:
            bad=Path(t)/'bad.json';out=Path(t)/'out.bin'
            for payload in ('not json', '{"tag":1}',
                  json.dumps(dict(json.loads(DEMO.read_text()),alpha=500)),
                  json.dumps(dict(json.loads(DEMO.read_text()),unknown=1))):
                bad.write_text(payload)
                p=subprocess.run([sys.executable,str(CLI),'encode','--spec',str(bad),
                                  '--output',str(out)],capture_output=True)
                self.assertNotEqual(p.returncode,0)
                self.assertFalse(out.exists())

    def test_corrupted_capture_inspect_fails(self):
        with tempfile.TemporaryDirectory() as t:
            pkt=Path(t)/'packet.bin'
            subprocess.run([sys.executable,str(CLI),'encode','--spec',str(DEMO),
                            '--output',str(pkt)],check=True,capture_output=True)
            data=bytearray(pkt.read_bytes());data[20]^=1;pkt.write_bytes(data)
            p=subprocess.run([sys.executable,str(CLI),'inspect','--input',str(pkt)],
                             capture_output=True)
            self.assertNotEqual(p.returncode,0)

if __name__=='__main__':unittest.main()
