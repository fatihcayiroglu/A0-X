"""P128 fail-closed parser tests; not substitute for real Yosys/nextpnr."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

P = Path(__file__).resolve().parents[1] / "tools" / "a0_p128_ice40_pnr.py"
spec = importlib.util.spec_from_file_location("a0_p128_ice40_pnr", P)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def fixture(clock=True):
    return {"utilization": {"ICESTORM_LC": {"used": 170, "available": 7680},
                            "SB_IO": {"used": 3, "available": 206},
                            "ICESTORM_RAM": {"used": 2, "available": 32}},
            "fmax": {"clk": {"achieved": 12.35, "constraint": 5.0}} if clock else {}}


class EvidenceTests(unittest.TestCase):
    def test_accept_clock(self):
        r = mod.summarize_report(fixture(), True)
        self.assertTrue(r["internal_clock_timing_met"])
        self.assertEqual(r["resources"]["ICESTORM_LC"]["used"], 170)

    def test_accept_pure_comb(self):
        r = mod.summarize_report(fixture(False), False)
        self.assertFalse(r["internal_clock_timing_met"])

    def test_no_clock_is_not_proof(self):
        with self.assertRaisesRegex(ValueError, "no post-route timing"):
            mod.summarize_report(fixture(False), True)

    def test_reject_timing_violation(self):
        f = fixture(); f["fmax"]["clk"]["achieved"] = 4.99
        with self.assertRaisesRegex(ValueError, "timing violation"):
            mod.summarize_report(f, True)

    def test_reject_wrong_constraint(self):
        f = fixture(); f["fmax"]["clk"]["constraint"] = 1
        with self.assertRaisesRegex(ValueError, "mismatched constraint"):
            mod.summarize_report(f, True)

    def test_reject_oversubscribed(self):
        f = fixture(); f["utilization"]["ICESTORM_LC"]["used"] = 9000
        with self.assertRaisesRegex(ValueError, "excess utilization"):
            mod.summarize_report(f, True)

    def test_reject_optimised_away(self):
        f = fixture(); f["utilization"]["ICESTORM_LC"]["used"] = 0
        with self.assertRaisesRegex(ValueError, "optimized away"):
            mod.summarize_report(f, True)

    def test_reject_missing_io(self):
        f = fixture(); del f["utilization"]["SB_IO"]
        with self.assertRaisesRegex(ValueError, "missing device"):
            mod.summarize_report(f, True)

    def test_reject_empty_report(self):
        with self.assertRaises(ValueError):
            mod.summarize_report({}, True)

    def test_reject_clock_on_comb(self):
        with self.assertRaisesRegex(ValueError, "unexpectedly"):
            mod.summarize_report(fixture(True), False)

    def test_command_device_and_seed(self):
        cmd = mod.nextpnr_command("nextpnr-ice40", Path("in.json"), Path("out.asc"), Path("report.json"))
        self.assertIn("--hx8k", cmd)
        self.assertIn("ct256", cmd)
        self.assertEqual(cmd[cmd.index("--freq") + 1], "5.0")
        self.assertEqual(cmd[cmd.index("--seed") + 1], "1")
        self.assertIn("--pcf-allow-unconstrained", cmd)
        self.assertNotIn("--timing-allow-fail", cmd)

    def test_no_tool_returns_not_run(self):
        with tempfile.TemporaryDirectory() as d:
            result = mod.run(Path(d), selected="p68_depth_compare", yosys="impossible-a0-yosys", nextpnr="impossible-a0-nextpnr")
            self.assertEqual(result, 2)
            import json
            j = json.loads((Path(d) / "p128_ice40_pnr.json").read_text())
            self.assertEqual(j["status"], "NOT_RUN")
            self.assertEqual(j["targets_passed"], 0)
            self.assertFalse(j["physical_board_tested"])


if __name__ == "__main__":
    unittest.main()