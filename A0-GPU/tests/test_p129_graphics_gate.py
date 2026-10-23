"""Host-side fail-closed tests for real RTL P129 gate. Not an HDL simulation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

FILE = Path(__file__).resolve().parents[1] / "tools/a0_p129_graphics_gate.py"
spec = importlib.util.spec_from_file_location("a0_p129_graphics_gate", FILE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

GOOD = "P129_GRAPHICS_INTEGRATION_WITNESS triangles=3 committed_pixels=9 framebuffer=4x4\nP129_REAL_RTL_GRAPHICS_INTEGRATION_PASS\n"

class GateTests(unittest.TestCase):
    def test_exact_witness(self):
        self.assertEqual(mod.parse_witness(GOOD)["committed_pixel_events"], 9)

    def test_reject_empty(self):
        with self.assertRaises(ValueError): mod.parse_witness("")

    def test_reject_missing_marker(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD.replace(mod.WITNESS, ""))

    def test_reject_duplicate_marker(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD+mod.WITNESS+"\n")

    def test_reject_inexact_marker(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD.replace(mod.WITNESS, mod.WITNESS+"_FAKE"))

    def test_reject_wrong_pixel_count(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD.replace("committed_pixels=9", "committed_pixels=8"))

    def test_reject_wrong_triangle_count(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD.replace("triangles=3", "triangles=4"))

    def test_reject_fatal(self):
        with self.assertRaises(ValueError): mod.parse_witness(GOOD+"FATAL: late error\n")

    def test_module_paths_are_real_rtl(self):
        self.assertEqual(len(mod.SOURCES), 6)
        self.assertTrue(all(x.exists() for x in mod.SOURCES))
        self.assertTrue(any(x.name == "a0_triangle_scissor_depth_blend_p102.sv" for x in mod.SOURCES))

    def test_compile_uses_top_and_real_hdl(self):
        command=mod.build_command("iverilog", Path("test.vvp"))
        self.assertEqual(command[:2], ["iverilog", "-g2012"])
        self.assertIn("-s", command)
        self.assertIn("a0_p129_raster_depth_blend_integration_tb", command)
        self.assertIn(str(mod.TB), command)

    def test_missing_simulator_never_claims_pass(self):
        with tempfile.TemporaryDirectory() as p:
            folder=Path(p)
            self.assertEqual(mod.run(folder,iverilog="does-not-exist-a0-p129",vvp="does-not-exist-a0-vvp"),2)
            report=json.loads((folder/"p129_graphics.json").read_text())
            self.assertEqual(report["status"], "NOT_RUN")
            self.assertEqual(report["real_rtl_tests_passed"],0)
            self.assertFalse(report["physical_gpu_qualified"])
            self.assertFalse(report["display_output_qualified"])

    def test_no_fake_hardware_certification(self):
        with tempfile.TemporaryDirectory() as p:
            mod.run(Path(p),iverilog="missing-p129-iverilog",vvp="missing-p129-vvp")
            report=json.loads((Path(p)/"p129_graphics.json").read_text())
            self.assertFalse(report["pci_express_qualified"])
            self.assertFalse(report["fpga_timing_qualified"])
            self.assertFalse(report["device_programmed"])

    def test_coverage_scenarios_are_present(self):
        tb=mod.TB.read_text()
        for snippet in ("failed depth rejection", "scissored blend", "reset did not gate",
                        "out-of-range read not gated", "snapshotted", "framebuffer=4x4"):
            self.assertIn(snippet, tb)

if __name__=="__main__": unittest.main()