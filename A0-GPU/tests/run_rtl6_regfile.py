#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/core/a0_regfile_banked.sv"
TB = ROOT / "tests/rtl/a0_regfile_banked_tb.sv"

MARKERS = [
    "RTL6_RF_RESET_CONTROL=PASS",
    "RTL6_RF_BASIC_READ_WRITE=PASS",
    "RTL6_RF_MASKED_WRITE=PASS",
    "RTL6_RF_DIFFERENT_BANK_PARALLEL=PASS",
    "RTL6_RF_SAME_BANK_CONFLICT=PASS",
    "RTL6_RF_READ_AFTER_WRITE_BYPASS=PASS",
    "RTL6_RF_BEAT_ISOLATION=PASS",
    "RTL6_BANKED_REGFILE_TB=PASS",
]


def run(command, cwd):
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            "command failed with exit code "
            f"{result.returncode}: {' '.join(map(str, command))}"
        )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix="a0_rtl6_regfile_") as temp_dir:
        build_dir = Path(temp_dir) / "obj_dir"
        build_dir.mkdir(parents=True, exist_ok=True)

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-fatal",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "--top-module",
                "a0_regfile_banked_tb",
                "--Mdir",
                str(build_dir),
                str(RTL),
                str(TB),
            ],
            ROOT,
        )

        output = run([str(build_dir / "Va0_regfile_banked_tb")], ROOT)
        missing = [marker for marker in MARKERS if marker not in output]
        if missing:
            raise RuntimeError("missing RTL6 RF marker(s): " + ", ".join(missing))

        print("RTL6_BANKED_REGFILE_DRIVER=PASS")


if __name__ == "__main__":
    main()
