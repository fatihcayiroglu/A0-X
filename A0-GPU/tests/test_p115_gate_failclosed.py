"""Mocks only verify P115 gate CONTROL FLOW; not RTL simulation evidence."""
import contextlib,io,pathlib,sys,unittest
from unittest.mock import patch,Mock
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
import run_p115_frame_event_audit as gate

class GateCases(unittest.TestCase):
    def call(self,runs,tool=True):
        with patch.object(gate.shutil,'which',return_value='/fake/iverilog' if tool else None),\
             patch.object(gate.subprocess,'run',side_effect=runs) as sub,\
             contextlib.redirect_stdout(io.StringIO()):
            result=gate.run()
            return result,sub.call_count
    def test_missing_iverilog_returns_not_run(self):
        self.assertEqual(self.call([],False),(2,0))
    def test_compile_failure(self):
        self.assertEqual(self.call([Mock(returncode=1,stdout='',stderr='syntax')]),(1,1))
    def test_vvp_failure(self):
        self.assertEqual(self.call([Mock(returncode=0,stdout='',stderr=''),
                                    Mock(returncode=1,stdout='',stderr='FATAL')]),(1,2))
    def test_vvp_without_pass_marker(self):
        self.assertEqual(self.call([Mock(returncode=0,stdout='',stderr=''),
                                    Mock(returncode=0,stdout='',stderr='')]),(1,2))
    def test_top_elaboration_failure(self):
        self.assertEqual(self.call([Mock(returncode=0,stdout='',stderr=''),
                                   Mock(returncode=0,stdout=gate.MARKER,stderr=''),
                                   Mock(returncode=1,stdout='',stderr='port mismatch')]),(1,3))
    def test_only_mocked_control_flow_can_return_success(self):
        self.assertEqual(self.call([Mock(returncode=0,stdout='',stderr=''),
                                   Mock(returncode=0,stdout=gate.MARKER,stderr=''),
                                   Mock(returncode=0,stdout='',stderr='')]),(0,3))
if __name__=='__main__':unittest.main()
