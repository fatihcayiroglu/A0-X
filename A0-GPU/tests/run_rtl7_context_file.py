#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

RTL = ROOT / "rtl/scheduler/a0_wave_context_file.sv"
TB = ROOT / "tests/rtl/a0_wave_context_file_tb.sv"

MARKERS = ['RTL7_CTX_RESET_CONTROL=PASS', 'RTL7_CTX_ALLOCATE=PASS', 'RTL7_CTX_ISOLATION=PASS', 'RTL7_CTX_RECONV=PASS', 'RTL7_CTX_VRF_OWNERSHIP=PASS', 'RTL7_CTX_READY_MASK=PASS', 'RTL7_CTX_RELEASE=PASS', 'RTL7_CONTEXT_FILE_TB=PASS']


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
        prefix="a0_rtl7_context_"
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
                "a0_wave_context_file_tb",
                "--Mdir",
                str(build_dir),
                str(RTL),
                str(TB),
            ],
            ROOT,
        )

        output = run(
            [str(build_dir / "Va0_wave_context_file_tb")],
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

        print("RTL7_CONTEXT_FILE_DRIVER=PASS")


if __name__ == "__main__":
    main()
