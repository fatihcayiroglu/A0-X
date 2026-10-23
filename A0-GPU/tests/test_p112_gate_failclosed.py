"""P112 verification gate must never report PASS for absent/broken HDL tools."""
import contextlib
import io
from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch,Mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
import run_p112_watchdog_trace as gate

class P112GateTests(unittest.TestCase):
    def quiet(self):
        return contextlib.redirect_stdout(io.StringIO())

    def test_absent_simulator_returns_not_run(self):
        with patch.object(gate.shutil,'which',return_value=None), self.quiet():
            self.assertEqual(gate.run(),2)

    def test_invalid_metadata_fails_before_tool_lookup(self):
        with tempfile.TemporaryDirectory() as tmp:
            meta=json.loads(gate.META.read_text())
            meta['sha256']='0'*64
            bad=Path(tmp)/'bad.json';bad.write_text(json.dumps(meta))
            with patch.object(gate,'META',bad),self.quiet():
                self.assertEqual(gate.run(),1)

    def test_compiler_failure_is_not_success(self):
        proc=Mock(returncode=1,stdout='syntax error')
        with patch.object(gate.shutil,'which',return_value='/usr/bin/fake'), \
             patch.object(gate.subprocess,'run',return_value=proc) as sub, self.quiet():
            self.assertEqual(gate.run(),1)
            self.assertEqual(sub.call_count,1)

    def test_compiler_pass_but_simulator_failure_is_not_success(self):
        compile_ok=Mock(returncode=0,stdout='')
        simulate_fail=Mock(returncode=1,stdout='FATAL')
        with patch.object(gate.shutil,'which',return_value='/usr/bin/fake'), \
             patch.object(gate.subprocess,'run',side_effect=[compile_ok,simulate_fail]) as sub, self.quiet():
            self.assertEqual(gate.run(),1)
            self.assertEqual(sub.call_count,2)

    def test_simulator_without_success_marker_is_not_success(self):
        ok=Mock(returncode=0,stdout='')
        with patch.object(gate.shutil,'which',return_value='/usr/bin/fake'), \
             patch.object(gate.subprocess,'run',return_value=ok),self.quiet():
            self.assertEqual(gate.run(),1)

    def test_mock_success_path_is_control_flow_only(self):
        ok_compile=Mock(returncode=0,stdout='')
        mock_simulate=Mock(returncode=0,stdout='P112_WATCHDOG_RTL_CYCLE_TRACE_PASS cycles=4096')
        with patch.object(gate.shutil,'which',return_value='/usr/bin/fake'), \
             patch.object(gate.subprocess,'run',side_effect=[ok_compile,mock_simulate]),self.quiet():
            # Mock return value tests gate logic, NOT a real HDL qualification.
            self.assertEqual(gate.run(),0)

if __name__=='__main__':unittest.main()
