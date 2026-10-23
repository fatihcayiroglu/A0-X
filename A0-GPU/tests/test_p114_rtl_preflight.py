"""Static binding regression and deliberate source mutation tests; not HDL."""
import pathlib,shutil,sys,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import a0_p114_rtl_preflight as checker

class StaticPreflightTests(unittest.TestCase):
    def test_real_tree(self):
        result=checker.audit(ROOT)
        self.assertEqual(result['status'],'PASS')
        self.assertEqual(result['new_port_bindings'],21)
        self.assertEqual(result['inherited_submodules_unchanged'],7)
        self.assertFalse(result['rtl_compiled'])
    def mutate(self,filename,old,new):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            shutil.copytree(ROOT/'rtl',root/'rtl')
            p=root/'rtl/graphics'/filename
            s=p.read_text();self.assertIn(old,s)
            p.write_text(s.replace(old,new,1))
            with self.assertRaises((checker.p110.WiringError,ValueError,KeyError)):
                checker.audit(root)
    def test_rewired_pixel_ready(self):
        self.mutate(checker.TOP+'.sv','.pixel_ready(pixel_ready),\n        .pixel_x(pixel_x)',
            '.pixel_ready(pixel_valid),\n        .pixel_x(pixel_x)')
    def test_rewired_frame_done(self):
        self.mutate(checker.TOP+'.sv','.end_of_frame(end_of_frame),.frame_done(frame_done)',
            '.end_of_frame(end_of_frame),.frame_done(scan_active)')
    def test_wrong_fault_net(self):
        self.mutate(checker.TOP+'.sv','.fault_sticky(frame_liveness_fault)',
            '.fault_sticky(diagnostic_fault)')
    def test_duplicate_guard_instance(self):
        self.mutate(checker.TOP+'.sv','a0_scanout_liveness_guard_p114 #(',
            'a0_scanout_liveness_guard_p114 duplicate_monitor (.clk(clk));\n    a0_scanout_liveness_guard_p114 #(')
    def test_missing_monitor_pin(self):
        self.mutate(checker.TOP+'.sv','.last_fault_y(frame_liveness_fault_y)',
            '.last_fault_yy(frame_liveness_fault_y)')
    def test_inherited_datapath_drift(self):
        self.mutate(checker.TOP+'.sv','.result_cycles(elapsed_q)',
            '.result_cycles(accepted_pixels)')
    def test_timeout_rule_deleted(self):
        self.mutate(checker.MON+'.sv','no_progress_q>=MAX_NO_PROGRESS_CYCLES-1',
            'no_progress_q==32\'hffffffff')
    def test_stall_integrity_deleted(self):
        self.mutate(checker.MON+'.sv','pixel_color!=held_color_q',
            'pixel_color==held_color_q')
    def test_missing_geometry_params(self):
        self.mutate(checker.TOP+'.sv','a0_scanout_liveness_guard_p114 #(\n        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)',
            'a0_scanout_liveness_guard_p114 #(\n        .FRAME_WIDTH(8),.FRAME_HEIGHT(FRAME_HEIGHT)')
if __name__=='__main__':unittest.main()
