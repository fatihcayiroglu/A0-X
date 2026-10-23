#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

CONTEXT = ROOT / "rtl/scheduler/a0_wave_context_file.sv"
SCHED = ROOT / "rtl/scheduler/a0_wave_scheduler.sv"
FRONTEND = ROOT / "rtl/scheduler/a0_multi_wave_frontend.sv"
TB = ROOT / "tests/rtl/a0_multi_wave_frontend_tb.sv"

MARKERS = ['RTL7_FRONTEND_SELECTED_CONTEXT=PASS', 'RTL7_FRONTEND_EXTERNAL_BLOCK=PASS', 'RTL7_FRONTEND_ARCH_BLOCK=PASS', 'RTL7_FRONTEND_POLICY_BOUNDARY=PASS', 'RTL7_FRONTEND_GRANT_HANDOFF=PASS', 'RTL7_FRONTEND_POLICY_METADATA=PASS', 'RTL7_FRONTEND_RELEASE=PASS', 'RTL7_MULTI_WAVE_FRONTEND_TB=PASS']


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
        joined = " ".join(map(str, command))
        raise RuntimeError(
            "command failed with exit code "
            f"{result.returncode}: {joined}"
        )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl7_frontend_"
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
                "-Werror-WIDTHTRUNC",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "--top-module",
                "a0_multi_wave_frontend_tb",
                "--Mdir",
                str(build_dir),
                str(CONTEXT),
                str(SCHED),
                str(FRONTEND),
                str(TB),
            ],
            ROOT,
        )

        output = run(
            [str(build_dir / "Va0_multi_wave_frontend_tb")],
            ROOT,
        )

        missing = [
            marker
            for marker in MARKERS
            if marker not in output
        ]
        if missing:
            raise RuntimeError(
                "missing marker(s): "
                + ", ".join(missing)
            )

        print("RTL7_MULTI_WAVE_FRONTEND_DRIVER=PASS")


if __name__ == "__main__":
    main()
