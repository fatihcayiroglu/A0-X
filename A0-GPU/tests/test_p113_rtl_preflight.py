"""Static source checks including mutation negatives, no RTL simulation claim."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
MODULE=ROOT/'tools/a0_p113_rtl_preflight.py'
spec=importlib.util.spec_from_file_location('p113preflight',MODULE)
p113=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p113)

class P113StaticPreflight(unittest.TestCase):
    def test_original(self):
        result=p113.audit(ROOT)
        self.assertEqual(result['monitor_connections'],len(p113.PORTS))
        self.assertFalse(result['rtl_simulated'])
        self.assertEqual(result['status'],'PASS')
    def mutant(self, filename, old, new):
        with tempfile.TemporaryDirectory() as td:
            temp=Path(td);(temp/'rtl/graphics').mkdir(parents=True)
            for name in p113.p110.SOURCES:
                shutil.copy(ROOT/'rtl/graphics'/name,temp/'rtl/graphics'/name)
            for name in [p113.p111.TOP+'.sv',p113.p111.WATCH+'.sv',p113.TOP+'.sv',p113.MON+'.sv']:
                shutil.copy(ROOT/'rtl/graphics'/name,temp/'rtl/graphics'/name)
            target=temp/'rtl/graphics'/filename
            s=target.read_text()
            self.assertIn(old,s)
            target.write_text(s.replace(old,new,1))
            with self.assertRaises(p113.p110.WiringError):p113.audit(temp)
    def test_swapped_output_binding_is_rejected(self):
        self.mutant(p113.TOP+'.sv','.present_pixel_count(diagnostic_present_pixels)',
                    '.present_pixel_count(diagnostic_timeouts)')
    def test_opcode_pin_loss_is_rejected(self):
        self.mutant(p113.TOP+'.sv','.cmd_opcode(cmd_opcode),.pixel_valid(pixel_valid)',
                    '.cmd_opcode(),.pixel_valid(pixel_valid)')
    def test_render_data_path_drift_is_rejected(self):
        self.mutant(p113.TOP+'.sv','.cmd_color(cmd_color)', '.cmd_color(cmd_depth)')
    def test_missing_progress_branch_is_rejected(self):
        self.mutant(p113.MON+'.sv','active_present_q && pixel_valid && !pixel_ready',
                    'active_present_q && pixel_valid && pixel_ready')
    def test_missing_pixel_input_is_rejected(self):
        self.mutant(p113.MON+'.sv','input logic pixel_valid,pixel_ready,',
                    'input logic pixel_valid,')

if __name__=='__main__':unittest.main()
