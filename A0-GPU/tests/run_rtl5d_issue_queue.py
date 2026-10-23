#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

RTL = ROOT / "rtl/core/a0_issue_queue.sv"
TB = ROOT / "tests/rtl/a0_issue_queue_tb.sv"

MARKERS = [
    "ISSUE_QUEUE_METADATA=PASS",
    "ISSUE_QUEUE_Q1_UNUSED_SRC2=PASS",
    "ISSUE_QUEUE_Q2_SCALAR_ALIAS=PASS",
    "ISSUE_QUEUE_Q3_VECTOR_WAW=PASS",
    "ISSUE_QUEUE_Q4_PREDICATE_RAW=PASS",
    "ISSUE_QUEUE_PREDICATE_WAW=PASS",
    "ISSUE_QUEUE_READY_BYPASS=PASS",
    "ISSUE_QUEUE_OLDEST_READY=PASS",
    "ISSUE_QUEUE_FULL_BACKPRESSURE=PASS",
    "ISSUE_QUEUE_SAME_CYCLE_REFILL=PASS",
    "RTL5E_ISSUE_QUEUE_TB=PASS",
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
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl5e_issue_queue_"
    ) as temp_dir:
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
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "--top-module",
                "a0_issue_queue_tb",
                "--Mdir",
                str(build_dir),
                str(RTL),
                str(TB),
            ],
            ROOT,
        )

        binary = build_dir / "Va0_issue_queue_tb"
        output = run([str(binary)], ROOT)

        missing = [marker for marker in MARKERS if marker not in output]
        if missing:
            raise RuntimeError(
                "missing RTL5E marker(s): " + ", ".join(missing)
            )

        print("RTL5E_ISSUE_QUEUE_DRIVER=PASS")


if __name__ == "__main__":
    main()
