"""P126 fail-closed qualification evidence unit tests (not HDL)."""
import sys
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import a0_p126_qualification as gate

class QualificationTest(unittest.TestCase):
    def test_regression_names_include_p125_and_p126(self):
        self.assertEqual(gate.SUITES, (117,118,119,120,121,122,123,124,125,126))
    def test_new_sources_in_snapshot(self):
        paths=gate.snapshot()
        for rel in ('sim/a0_p126_reset_boundary_receiver.py',
                    'tests/test_p126_reset_boundary_receiver.py',
                    'tools/a0_p126_qualification.py'):
            self.assertIn(rel,paths)
    def test_empty_test_suites_not_accepted(self):
        self.assertEqual(gate.assess_tests(0,'Ran 0 tests in 0.000s\n\nOK\n'),(False,0))
    def test_skipped_test_suite_not_accepted(self):
        self.assertFalse(gate.assess_tests(0,'Ran 2 tests in 0.003s\nOK (skipped=1)\n')[0])
    def test_nonzero_test_exit_not_accepted(self):
        self.assertFalse(gate.assess_tests(1,'Ran 2 tests in 0.003s\nOK\n')[0])
    def test_good_suite_accepted(self):
        self.assertEqual(gate.assess_tests(0,'Ran 2 tests in 0.003s\n\nOK\n'),(True,2))
    def test_missing_18_real_gates_refused(self):
        self.assertFalse(gate.inherited_valid({'status':'PASS','qualified':True},0,Path('/invalid')))
        self.assertFalse(gate.inherited_valid({'status':'NOT_RUN','qualified':False},2,Path('/invalid')))
    def test_physical_qualification_not_promised(self):
        self.assertEqual(gate.snapshot()['tools/a0_p126_qualification.py'],
                         gate.digest(ROOT/'tools/a0_p126_qualification.py'))
if __name__=='__main__':unittest.main()
