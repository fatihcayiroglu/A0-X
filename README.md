# A0-X GPU — P126 development and real-RTL qualification

This is a source-development repository, **not a manufactured or qualified GPU**.

## Continuous integration

The only active root workflow is `.github/workflows/a0-p126-reset-boundary-18-real-rtl.yml`.
It installs real `iverilog` and `vvp`, runs P117–P126 Python regression tests,
then requires the existing 18 RTL simulation gates to pass without skips.
Generated evidence is uploaded as a GitHub Actions artifact, even when the job fails.

Old workflows are retained under `ci/archived-workflows/` for provenance, but are
not active GitHub Actions workflows, reducing duplicate initial CI runs.

To reproduce on Linux with Icarus Verilog installed:

```bash
python3 -B A0-GPU/tools/a0_p126_qualification.py --evidence EVIDENCE/P126/qualification
```

Exit codes: `0` = verified RTL gates pass; `1` = failure; `2` = **NOT_RUN**.
An RTL PASS is **not** FPGA/board/physical GPU qualification.

The original full P126 ZIP contains historical status reports and local NOT_RUN
logs; those historical artifacts are intentionally not committed here.
