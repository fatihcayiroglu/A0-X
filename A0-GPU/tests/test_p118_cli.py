"""P118 stand-alone CLI audits simulated capture, not hardware."""
import json
import contextlib
import io
from types import SimpleNamespace
import sys
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from a0_p118_loss_audit import main as audit_main
EXAMPLE=ROOT/'examples/p118/software_only_tail_loss.bin'
class TestP118Cli(unittest.TestCase):
    def run_tool(self,*args):
        out=io.StringIO();err=io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc=audit_main(list(args))
        return SimpleNamespace(returncode=rc,stdout=out.getvalue(),stderr=err.getvalue())
    def test_good_simulated_loss_witness(self):
        p=self.run_tool('--capture',str(EXAMPLE),'--final-dropped','2')
        self.assertEqual(p.returncode,0,p.stderr)
        r=json.loads(p.stdout)
        self.assertEqual((r['notices'],r['last_witnessed_drops']), (1,2))
        self.assertFalse(r['physical_hardware_verified'])
    def test_mismatch_is_failure(self):
        p=self.run_tool('--capture',str(EXAMPLE),'--final-dropped','3')
        self.assertEqual(p.returncode,1)
        self.assertIn('FAIL',p.stderr)
    def test_corrupted_wire_is_failure(self):
        with tempfile.TemporaryDirectory() as d:
            b=bytearray(EXAMPLE.read_bytes());b[-1]^=1
            f=Path(d)/'bad.bin';f.write_bytes(b)
            self.assertEqual(self.run_tool('--capture',str(f)).returncode,1)
    def test_missing_file_is_failure(self):
        self.assertEqual(self.run_tool('--capture','/nonexistent_p118_capture_abc').returncode,1)
