"""Mocked gate integrity tests: MUST NOT be described as real HDL PASS."""
from unittest import TestCase,mock
from pathlib import Path
import importlib.util,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))

def load(name):
    path=ROOT/'tests'/name
    spec=importlib.util.spec_from_file_location(name[:-3],path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

class TestGate(TestCase):
    def test_missing_simulator_returns_two(self):
        for f in ('run_p118_loss_fifo.py','run_p118_host_loss_e2e.py'):
            g=load(f)
            with mock.patch.object(g.shutil,'which',return_value=None):self.assertEqual(g.run(),2)
    def test_failed_compile_and_missing_executable_fail(self):
        for f in ('run_p118_loss_fifo.py','run_p118_host_loss_e2e.py'):
            g=load(f)
            for code in (0,1):
                with mock.patch.object(g.shutil,'which',return_value='/mock'),mock.patch.object(g.subprocess,'run',return_value=subprocess.CompletedProcess([],code,'','')):
                    self.assertEqual(g.run(),1)
    def test_fake_simulation_output_fails(self):
        for f in ('run_p118_loss_fifo.py','run_p118_host_loss_e2e.py'):
            g=load(f)
            for exitcode,output in ((1,g.MARKER),(0,'random success'),(0,g.MARKER+'\nFATAL:')):
                def fake(args,**kwargs):
                    if args[0]=='iverilog':
                        Path(args[args.index('-o')+1]).write_text('fake compiled file')
                        return subprocess.CompletedProcess(args,0,'','')
                    return subprocess.CompletedProcess(args,exitcode,output,'')
                with mock.patch.object(g.shutil,'which',return_value='/mock'),mock.patch.object(g.subprocess,'run',side_effect=fake):
                    self.assertEqual(g.run(),1)
    def test_true_marker_path_still_mocked_only(self):
        for f in ('run_p118_loss_fifo.py','run_p118_host_loss_e2e.py'):
            g=load(f)
            def fake(args,**kwargs):
                if args[0]=='iverilog':
                    Path(args[args.index('-o')+1]).write_text('fake')
                    return subprocess.CompletedProcess(args,0,'','')
                return subprocess.CompletedProcess(args,0,g.MARKER,'')
            with mock.patch.object(g.shutil,'which',return_value='/mock'),mock.patch.object(g.subprocess,'run',side_effect=fake):
                self.assertEqual(g.run(),0)
    def test_actual_gates_reference_new_rtl(self):
        self.assertIn('a0_scanout_telemetry_loss_fifo_p118.sv',(ROOT/'tests/run_p118_loss_fifo.py').read_text())
        b=load('run_p118_host_loss_e2e.py')
        self.assertIn('a0_scanout_telemetry_loss_fifo_p118.sv',b.SOURCES)
        self.assertIn('a0_host_fragment_dual_bank_bridge_p118.sv',b.SOURCES)
        self.assertNotIn('a0_host_fragment_dual_bank_bridge_p106.sv',b.SOURCES)
