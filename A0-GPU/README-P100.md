# A0-X GPU P100 — scoped development bundle (P56–P100)

**SOFTWARE DEVELOPMENT MILESTONES P56–P100 DEMONSTRATED; FULL RTL NOT RUN; NOT CLOSED.**

P56–P100 are deliberately small, testable *software reference features* for a
future GPU pipeline, not release-maturity percentages. All prior P55 files
are retained, and the separate 1.4 GB original P36 checkpoint is not duplicated.

Re-run full Python regression:

```bash
cd A0-GPU
python3 -m unittest discover -s tests -p 'test_*.py' -q
python3 tools/a0_p100_integrated_demo.py --output ../EVIDENCE/P100/demo
```

For RTL **later**, use `bash A0-GPU/tests/rtl/run_p100_candidate_gate.sh` and
follow `A0-GPU/docs/p56-p100/ARCHITECTURE_SCOPE.md` for inherited HDL gates.
This build did NOT run RTL simulation, synthesis or hardware.

Consult `P56-P100-MILESTONE-LEDGER.md`, `P100-STATUS.md` and the evidence directory.
