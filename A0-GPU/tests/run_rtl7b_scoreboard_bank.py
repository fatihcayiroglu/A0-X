#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

MARKERS = [
    "RTL7B_SCOREBOARD_RESET=PASS",
    "RTL7B_SCOREBOARD_VECTOR_ISOLATION=PASS",
    "RTL7B_SCOREBOARD_RELEASE_ISOLATION=PASS",
    "RTL7B_SCOREBOARD_PREDICATE_ISOLATION=PASS",
    "RTL7B_SCOREBOARD_CONTEXT_CLEAR=PASS",
    "RTL7B_WAVE_SCOREBOARD_BANK_TB=PASS",
]


def run(command):
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            "command failed with exit code "
            f"{result.returncode}: "
            + " ".join(map(str, command))
        )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl7b_scoreboard_bank_"
    ) as temp_dir:
        obj_dir = Path(temp_dir) / "obj_dir"

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-fatal",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_wave_scoreboard_bank_tb",
                "--Mdir",
                str(obj_dir),
                str(ROOT / "rtl/core/a0_scoreboard.sv"),
                str(ROOT / "rtl/scheduler/a0_wave_scoreboard_bank.sv"),
                str(ROOT / "tests/rtl/a0_wave_scoreboard_bank_tb.sv"),
            ]
        )

        output = run(
            [str(obj_dir / "Va0_wave_scoreboard_bank_tb")]
        )

        missing = [marker for marker in MARKERS if marker not in output]
        if missing:
            raise RuntimeError(
                "missing RTL7B scoreboard marker(s): "
                + ", ".join(missing)
            )

    print("RTL7B_WAVE_SCOREBOARD_BANK_DRIVER=PASS")


if __name__ == "__main__":
    main()
