"""P122 qualifier rejection tests, NOT actual HDL qualification."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('p122_q',ROOT/'tools/a0_p122_rtl_qualification.py')
q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)

class QualificationContracts(unittest.TestCase):
    def test_p121_predecessor_is_not_modified(self):
        self.assertEqual(len(q.load_p121().GATES),14)

    def test_total_fifteen_gates(self):
        self.assertEqual(len(q.load_p121().GATES)+1,15)

    def test_new_source_and_tb_present(self):
        for f in q.REQUIRED:self.assertTrue(f.is_file())

    def test_new_witness_only_passes_once(self):
        self.assertEqual(q.assess_p122(0,q.P122_MARKER+'\n')[0],'PASS')

    def test_witness_wrong_exit_fails(self):
        self.assertEqual(q.assess_p122(1,q.P122_MARKER+'\n')[0],'FAIL')

    def test_witness_unrun_returns_unrun(self):
        self.assertEqual(q.assess_p122(2,q.P122_MARKER+'\n')[0],'NOT_RUN')

    def test_duplicate_witness_fails(self):
        self.assertEqual(q.assess_p122(0,(q.P122_MARKER+'\n')*2)[0],'FAIL')

    def test_embedded_witness_does_not_count(self):
        self.assertEqual(q.assess_p122(0,'WRAPPED_'+q.P122_MARKER+'\n')[0],'FAIL')

    def test_fake_success_with_not_run_diagnostic_fails(self):
        self.assertEqual(q.assess_p122(0,q.P122_MARKER+'\nNOT_RUN\n')[0],'FAIL')

    def test_fake_success_with_fatal_diagnostic_fails(self):
        self.assertEqual(q.assess_p122(0,q.P122_MARKER+'\nFATAL: bad\n')[0],'FAIL')

    def test_fake_success_with_traceback_fails(self):
        self.assertEqual(q.assess_p122(0,q.P122_MARKER+'\nTraceback (most recent call last)\n')[0],'FAIL')

    def test_timeout_null_exit_fails(self):
        self.assertEqual(q.assess_p122(None,q.P122_MARKER+'\n')[0],'FAIL')

    def test_mocked_p121_is_never_valid(self):
        r={'execution_mode':'MOCKED_UNIT_TEST','qualified':True,'status':'PASS'}
        ok,_=q.verify_p121(r,0,pathlib.Path('/no/such/path'))
        self.assertFalse(ok)

    def test_unqualified_real_p121_is_never_valid(self):
        r={'execution_mode':'REAL_SUBPROCESS','qualified':False,'status':'PASS'}
        ok,_=q.verify_p121(r,0,pathlib.Path('/no/such/path'))
        self.assertFalse(ok)

    def test_missing_gates_cannot_be_pass(self):
        r={'execution_mode':'REAL_SUBPROCESS','qualified':True,'status':'PASS','gates':[], 'sources':{'fake':'hash'}}
        ok,_=q.verify_p121(r,0,pathlib.Path('/no/such/path'))
        self.assertFalse(ok)

    def test_source_snapshot_contains_new_bench_and_rtl(self):
        snapshot=q.snapshot(ROOT)
        self.assertIn('tests/rtl/a0_p122_overflow_race_tb.sv',snapshot)
        self.assertIn('rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv',snapshot)
        self.assertIn('tests/run_p122_overflow_race.py',snapshot)

    def test_source_snapshot_detects_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            root=pathlib.Path(td)
            for path in ['tools/a0_p121_rtl_qualification.py','tools/a0_p122_rtl_qualification.py',
                         'tools/a0_p122_packet_oracle.py','tests/run_p122_overflow_race.py',
                         'tests/rtl/a0_p122_overflow_race_tb.sv']:
                f=root/path;f.parent.mkdir(parents=True,exist_ok=True);f.write_text('initial\n')
            before=q.snapshot(root)
            (root/'tests/rtl/a0_p122_overflow_race_tb.sv').write_text('changed\n')
            self.assertNotEqual(before,q.snapshot(root))

    def test_rtl_tb_cannot_succeed_without_toolchain(self):
        # If a genuine local toolchain is available, this test does not run a
        # simulator. CI does that independently in the required 15-gate job.
        import shutil
        if not (shutil.which('iverilog') and shutil.which('vvp')):
            import subprocess,sys
            proc=subprocess.run([sys.executable,str(q.P122_SCRIPT)],capture_output=True,text=True)
            self.assertEqual(proc.returncode,2)
            self.assertIn('NOT_RUN',proc.stdout)

if __name__=='__main__':unittest.main()
