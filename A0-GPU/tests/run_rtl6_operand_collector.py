#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REGFILE = ROOT / "rtl/core/a0_regfile_banked.sv"
COLLECTOR = ROOT / "rtl/core/a0_operand_collector.sv"
TB = ROOT / "tests/rtl/a0_operand_collector_tb.sv"

MARKERS = [
    "RTL6_COLLECTOR_RESET=PASS",
    "RTL6_COLLECTOR_3SRC_NO_CONFLICT=PASS",
    "RTL6_COLLECTOR_SAME_BANK_SERIALIZE=PASS",
    "RTL6_COLLECTOR_DISABLED_SOURCE_ZERO=PASS",
    "RTL6_COLLECTOR_BACKPRESSURE_STABLE=PASS",
    "RTL6_COLLECTOR_ZERO_BUBBLE_HANDOFF=PASS",
    "RTL6_OPERAND_COLLECTOR_TB=PASS",
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
    with tempfile.TemporaryDirectory(prefix="a0_rtl6_collector_") as temp_dir:
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
                "a0_operand_collector_tb",
                "--Mdir",
                str(build_dir),
                str(REGFILE),
                str(COLLECTOR),
                str(TB),
            ],
            ROOT,
        )

        output = run([str(build_dir / "Va0_operand_collector_tb")], ROOT)
        missing = [marker for marker in MARKERS if marker not in output]
        if missing:
            raise RuntimeError(
                "missing RTL6 collector marker(s): " + ", ".join(missing)
            )

        print("RTL6_OPERAND_COLLECTOR_DRIVER=PASS")


if __name__ == "__main__":
    main()
