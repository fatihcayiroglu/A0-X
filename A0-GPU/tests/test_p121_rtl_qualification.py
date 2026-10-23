"""P121 orchestration unit tests: MOCKED runners cannot certify hardware.

Real Icarus qualification is ONLY the unmapped CLI run of
`tools/a0_p121_rtl_qualification.py` on an Icarus-equipped host.
"""
import importlib.util
from pathlib import Path
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT/'tools/a0_p121_rtl_qualification.py'
spec = importlib.util.spec_from_file_location('p121_gate', MOD)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class GateEvaluationTests(unittest.TestCase):
    def test_all_gate_files_present(self):
        for _, runner, _ in gate.GATES:
            self.assertTrue((ROOT/'tests'/runner).is_file())

    def test_exact_14_gates(self):
        self.assertEqual(len(gate.GATES), 14)
        self.assertEqual(len({x[0] for x in gate.GATES}), 14)
        self.assertEqual(len({x[1] for x in gate.GATES}), 14)

    def test_all_tb_witnesses_present(self):
        witnesses = '\n'.join(x.read_text() for x in (ROOT/'tests/rtl').glob('*.sv'))
        for _, _, marker in gate.GATES:
            self.assertIn(marker, witnesses)

    def test_pass_only_once(self):
        for _, _, marker in gate.GATES:
            self.assertEqual(gate.assess(0, marker+'\n', marker)[0], 'PASS')

    def test_reject_no_marker(self):
        self.assertEqual(gate.assess(0,'fake PASS\n','EXPECTED')[0],'FAIL')

    def test_reject_embedded_marker(self):
        self.assertEqual(gate.assess(0,'WRAPPED_EXPECTED\n','EXPECTED')[0],'FAIL')

    def test_reject_duplicate_witness(self):
        self.assertEqual(gate.assess(0,'EXPECTED\nEXPECTED\n','EXPECTED')[0],'FAIL')

    def test_reject_nonzero_even_with_marker(self):
        self.assertEqual(gate.assess(1,'EXPECTED\n','EXPECTED')[0],'FAIL')

    def test_not_run_not_pass_even_with_marker(self):
        self.assertEqual(gate.assess(2,'EXPECTED\n','EXPECTED')[0],'NOT_RUN')

    def test_not_run_text_fails(self):
        self.assertEqual(gate.assess(0,'EXPECTED\nRTL_NOT_RUN\n','EXPECTED')[0],'FAIL')

    def test_fatal_text_fails(self):
        self.assertEqual(gate.assess(0,'EXPECTED\nFATAL: bad\n','EXPECTED')[0],'FAIL')

    def test_traceback_text_fails(self):
        self.assertEqual(gate.assess(0,'EXPECTED\nTraceback (most recent call last)\n','EXPECTED')[0],'FAIL')

    def test_prefix_with_suffix_accepted(self):
        self.assertEqual(gate.assess(0,'EXPECTED cycles=4096\n','EXPECTED')[0],'PASS')

    def test_invalid_suffix_attached_fails(self):
        self.assertEqual(gate.assess(0,'EXPECTED_FAKE\n','EXPECTED')[0],'FAIL')


class MockedOrchestrationTests(unittest.TestCase):
    """These fixtures verify failure semantics, not RTL execution."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name)/'A0-GPU'
        (self.project/'tests').mkdir(parents=True)
        (self.project/'rtl/graphics').mkdir(parents=True)
        (self.project/'tests/rtl').mkdir(parents=True)
        (self.project/'tools').mkdir(parents=True)
        (self.project/'rtl/graphics/example.sv').write_text('module foo; endmodule\n')
        (self.project/'tests/rtl/example.sv').write_text('module tb; endmodule\n')
        (self.project/'tools/a0_p121_rtl_qualification.py').write_bytes(MOD.read_bytes())
        for name, script, marker in gate.GATES:
            (self.project/'tests'/script).write_text('# stub '+name+'\n')
        self.evidence = Path(self.tmp.name)/'evidence'
        self.locate = lambda name: '/mock/'+name

    def fake_success(self, python, runner, project, timeout):
        marker = next(marker for name, script, marker in gate.GATES if runner.name==script)
        return (0,marker+'\n')

    def test_mock_success_runs_all_fourteen_but_cannot_prove_rtl(self):
        code, report = gate.run_all(self.project,self.evidence,locate=self.locate,
                                    execute=self.fake_success)
        self.assertEqual(code,1)
        self.assertFalse(report['qualified'])
        self.assertEqual(report['status'], 'MOCK_ONLY')
        self.assertEqual(report['execution_mode'], 'MOCKED_UNIT_TEST')
        self.assertTrue(all(g['status'] == 'MOCK_PASS' for g in report['gates']))
        self.assertEqual(len(report['gates']),14)
        self.assertFalse(report['physical_prototype'])
        self.assertEqual(len(report['sources']),len(set(report['sources'])))
        self.assertTrue((self.evidence/'qualification.json').is_file())
        self.assertTrue(all((self.evidence/g['log']).is_file() for g in report['gates']))
        # Fixture is explicitly mocked, NOT a hardware qualification result.

    def test_injected_locator_alone_cannot_certify_rtl(self):
        # The production executor still runs in this test; a missing toy command
        # never turns this into simulated hardware qualification.
        code, report = gate.run_all(self.project,self.evidence,locate=self.locate,
                                    execute=self.fake_success)
        self.assertEqual(code,1)
        self.assertFalse(report['qualified'])
        self.assertEqual(sum(x['status']=='PASS' for x in report['gates']),0)

    def test_injected_result_with_exact_real_witness_remains_mock_only(self):
        code, report = gate.run_all(self.project,self.evidence,locate=self.locate,
                                    execute=self.fake_success)
        self.assertEqual(report['status'],'MOCK_ONLY')
        self.assertTrue(all(x['status']=='MOCK_PASS' for x in report['gates']))
        self.assertNotEqual(code,0)

    def test_missing_tool_blocks_every_gate(self):
        invoked=[]
        def execute(*args):invoked.append(args);return 0,''
        code, report=gate.run_all(self.project,self.evidence,
            locate=lambda name: '/mock/iv' if name=='iverilog' else None,execute=execute)
        self.assertEqual(code,2)
        self.assertFalse(invoked)
        self.assertFalse(report['qualified'])
        self.assertEqual(sum(g['status']=='NOT_RUN' for g in report['gates']),14)

    def test_one_gate_failure_blocks_suite(self):
        def execute(python, runner, project, timeout):
            return (1,'P118_REAL_RTL_LOSS_NOTICE_PASS\n') if 'loss_fifo' in runner.name else self.fake_success(python,runner,project,timeout)
        code, report=gate.run_all(self.project,self.evidence,locate=self.locate,execute=execute)
        self.assertEqual(code,1)
        self.assertFalse(report['qualified'])
        self.assertEqual(len(report['gates']),14)
        self.assertEqual(report['status'],'FAIL')

    def test_exception_and_timeout_blocks_suite(self):
        def execute(python, runner, project, timeout):
            if 'p116' in runner.name:raise TimeoutError('test timeout')
            return self.fake_success(python,runner,project,timeout)
        code, report=gate.run_all(self.project,self.evidence,locate=self.locate,execute=execute)
        self.assertEqual(code,1)
        self.assertTrue(any(g['reason']=='timeout' for g in report['gates']))

    def test_runner_reports_missing_while_toolchain_present(self):
        def execute(python, runner, project, timeout):
            if 'p111' in runner.name:return 2,'P111_REAL_RTL_NOT_RUN\n'
            return self.fake_success(python,runner,project,timeout)
        code, report=gate.run_all(self.project,self.evidence,locate=self.locate,execute=execute)
        self.assertEqual(code,1)
        self.assertTrue(any(g['status']=='NOT_RUN' for g in report['gates']))

    def test_deleted_gate_file_fails_before_running_any(self):
        (self.project/'tests'/gate.GATES[0][1]).unlink()
        calls=[]
        code, report=gate.run_all(self.project,self.evidence,locate=self.locate,
                       execute=lambda *args:calls.append(args))
        self.assertEqual(code,1)
        self.assertFalse(calls)
        self.assertEqual(report['status'],'FAIL')

    def test_manifest_detects_source_mutation(self):
        first=gate.source_hashes(self.project)
        (self.project/'rtl/graphics/example.sv').write_text('module modified; endmodule\n')
        second=gate.source_hashes(self.project)
        self.assertNotEqual(first['rtl/graphics/example.sv'],second['rtl/graphics/example.sv'])

    def test_log_checksum_reproducible(self):
        code, report=gate.run_all(self.project,self.evidence,locate=self.locate,
                                    execute=self.fake_success)
        self.assertEqual(code,1)
        for item in report['gates']:
            self.assertEqual(item['log_sha256'],gate.sha256((self.evidence/item['log']).read_bytes()))

    def test_json_report_atomic_and_parseable(self):
        code, report=gate.run_all(self.project,self.evidence,
                                  locate=lambda tool:None)
        self.assertEqual(code,2)
        saved=json.loads((self.evidence/'qualification.json').read_text())
        self.assertEqual(saved['status'],'NOT_RUN')
        self.assertEqual(saved['schema'],'A0-P121-RTL-QUALIFICATION-1')


if __name__=='__main__':
    unittest.main()
