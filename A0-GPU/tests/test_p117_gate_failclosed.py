"""P117 HDL launch gate tests. These are MOCKS, not real RTL execution."""
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase, mock
import subprocess

RUNNER = Path(__file__).with_name('run_p117_telemetry_fifo.py')
spec = importlib.util.spec_from_file_location('a0_p117_hdl_gate', RUNNER)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class P117GateTests(TestCase):
    def test_absent_tools_is_not_run(self):
        with mock.patch.object(gate.shutil, 'which', return_value=None):
            self.assertEqual(gate.run(), 2)

    def test_failed_compile_is_not_success(self):
        with mock.patch.object(gate.shutil, 'which', return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([],1,'','invalid port')):
            self.assertEqual(gate.run(),1)

    def test_fake_compile_zero_without_executable_is_not_success(self):
        with mock.patch.object(gate.shutil, 'which', return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([],0,'','')):
            self.assertEqual(gate.run(),1)

    def test_real_execution_failure_even_with_marker_is_not_success(self):
        def simulate(args,**kwargs):
            if args[0]=='iverilog':
                Path(args[args.index('-o')+1]).write_text('fake')
                return subprocess.CompletedProcess(args,0,'','')
            return subprocess.CompletedProcess(args,1,gate.MARKER+'\nFATAL: error','')
        with mock.patch.object(gate.shutil,'which',return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess,'run',side_effect=simulate):
            self.assertEqual(gate.run(),1)

    def test_sim_success_without_marker_is_not_success(self):
        def simulate(args,**kwargs):
            if args[0]=='iverilog':
                Path(args[args.index('-o')+1]).write_text('fake')
            return subprocess.CompletedProcess(args,0,'nonmatching output','')
        with mock.patch.object(gate.shutil,'which',return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess,'run',side_effect=simulate):
            self.assertEqual(gate.run(),1)

    def test_subprocess_timeout_not_success(self):
        with mock.patch.object(gate.shutil,'which',return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess,'run',side_effect=subprocess.TimeoutExpired('iverilog',1)):
            self.assertEqual(gate.run(),1)

    def test_only_proper_marker_and_exit_zero_accepted_by_gate_logic(self):
        # This is intentionally MOCKED: does not count as real RTL PASS.
        def simulate(args,**kwargs):
            if args[0]=='iverilog':
                Path(args[args.index('-o')+1]).write_text('fake')
                return subprocess.CompletedProcess(args,0,'','')
            return subprocess.CompletedProcess(args,0,gate.MARKER,'')
        with mock.patch.object(gate.shutil,'which',return_value='/bin/mock'), \
             mock.patch.object(gate.subprocess,'run',side_effect=simulate):
            self.assertEqual(gate.run(),0)

    def test_bridge_is_exact_p106_clone_except_fifo(self):
        src=RUNNER.parents[1]/'rtl'/'graphics'
        old=(src/'a0_host_fragment_dual_bank_bridge_p106.sv').read_text()
        new=(src/'a0_host_fragment_dual_bank_bridge_p117.sv').read_text()
        # Compare executable statements of every inherited instance other
        # than the explicitly replaced telemetry FIFO.
        new=new.replace('module a0_host_fragment_dual_bank_bridge_p117',
                        'module a0_host_fragment_dual_bank_bridge_p106')
        new=new.replace('    parameter int TELEMETRY_DEPTH=4,\n','')
        new=new.replace('output logic [31:0] telemetry_dropped_frames,\n    output logic [$clog2(TELEMETRY_DEPTH+1)-1:0] telemetry_queued_frames',
                        'output logic [31:0] telemetry_dropped_frames')
        new=new.replace('a0_scanout_telemetry_fifo_p117 #(.FIFO_DEPTH(TELEMETRY_DEPTH)) telemetry_sender',
                        'a0_scanout_telemetry_tx_p48 telemetry_sender')
        new=new.replace('.tx_byte(frame_tx_byte),.dropped_frame_events(telemetry_dropped_frames),\n        .queued_frame_events(telemetry_queued_frames)',
                        '.tx_byte(frame_tx_byte),.dropped_frame_events(telemetry_dropped_frames)')
        new=new.replace('// P117 DEVELOPMENT: P106 command path is unchanged; P48 single-slot\n'
                        '// telemetry sender replaced with a four-entry FIFO.\n','')
        self.assertEqual(new,old)

class P117IntegrationTests(TestCase):
    def test_two_frame_e2e_has_real_fifo_top_and_independent_crc(self):
        root=RUNNER.parents[1]
        b=(root/'tests/rtl/a0_host_telemetry_fifo_e2e_p117_tb.sv').read_text()
        self.assertIn('a0_host_fragment_dual_bank_bridge_p117 #(',b)
        self.assertIn('GOLD_CRC0=32\'h0b207310',b)
        self.assertIn('GOLD_CRC1=32\'h330e6e51',b)
        self.assertNotIn('repeat(160)',b)
        self.assertIn('telemetry_queued_frames!==0',b)

    def test_e2e_runner_uses_fifo_and_rejects_missing_simulator(self):
        import importlib.util
        r=RUNNER.with_name('run_p117_host_fifo_e2e.py')
        spec=importlib.util.spec_from_file_location('p117_e2e_gate_test',r)
        module=importlib.util.module_from_spec(spec)
        # load sibling imports, as when running executable
        import sys
        sys.path.insert(0,str(r.parent))
        spec.loader.exec_module(module)
        with mock.patch.object(module.shutil,'which',return_value=None):
            self.assertEqual(module.run(),2)
        self.assertIn('a0_scanout_telemetry_fifo_p117.sv',module.SOURCES)
        self.assertIn('a0_host_fragment_dual_bank_bridge_p117.sv',module.SOURCES)
        self.assertNotIn('a0_host_fragment_dual_bank_bridge_p106.sv',module.SOURCES)

    def test_p117_ci_is_manual_only(self):
        root=RUNNER.parents[2]
        # Historical manual-only workflow is archived, not an active CI gate.
        archived=root/'ci/archived-workflows/a0-p117-telemetry-fifo-rtl.yml'
        x=archived.read_text()
        self.assertIn('workflow_dispatch:',x)
        self.assertNotIn('push:',x)
        self.assertIn('run_p117_host_fifo_e2e.py',x)
        # Current P126 root workflow MUST be active and require real RTL.
        active=root/'.github/workflows/a0-p126-reset-boundary-18-real-rtl.yml'
        y=active.read_text()
        self.assertIn('push:',y)
        self.assertIn('a0_p126_qualification.py',y)
        self.assertIn('real_rtl_gates_verified',y)
