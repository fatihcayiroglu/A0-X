#!/usr/bin/env python3

from pathlib import Path
import os
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run(
    cmd,
    *,
    env=None,
):
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    print(
        result.stdout,
        end="",
    )

    if result.returncode:
        raise RuntimeError(
            "command failed: "
            + " ".join(cmd)
        )

    return result.stdout


def compile_source(path):
    compile(
        path.read_text(
            encoding="utf-8"
        ),
        str(path),
        "exec",
    )


def main():
    compile_source(
        ROOT
        / "tests/run_rtl9d3_shared_l2_integration.py"
    )

    compile_source(
        ROOT
        / "tests/run_rtl9d3_gate.py"
    )

    print(
        "RTL9D3_PYTHON_COMPILE=PASS"
    )

    # The closed RTL9D-2 regression gate still performs explicit
    # py_compile. Redirect every child Python bytecode cache outside
    # the staged repository tree.
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d3_gate_pycache_"
    ) as pycache_root:

        child_env = os.environ.copy()

        child_env[
            "PYTHONPYCACHEPREFIX"
        ] = pycache_root

        targeted = run(
            [
                sys.executable,
                str(
                    ROOT
                    / "tests/run_rtl9d3_shared_l2_integration.py"
                ),
            ],
            env=child_env,
        )

        if (
            "RTL9D3_SHARED_L2_INTEGRATION_DRIVER=PASS"
            not in targeted
        ):
            raise RuntimeError(
                "RTL9D-3 targeted marker missing"
            )

        print(
            "RTL9D3_TARGETED_SHARED_L2_INTEGRATION=PASS"
        )

        regression = run(
            [
                sys.executable,
                str(
                    ROOT
                    / "tests/run_rtl9d2_gate.py"
                ),
            ],
            env=child_env,
        )

        if (
            "RTL9D2_GATE=PASS"
            not in regression
        ):
            raise RuntimeError(
                "RTL9D-2 full regression marker missing"
            )

        print(
            "RTL9D3_RTL9D2_FULL_REGRESSION=PASS"
        )

    run([
        "git",
        "diff",
        "--check",
    ])

    run([
        "git",
        "diff",
        "--cached",
        "--check",
    ])

    print(
        "RTL9D3_GIT_DIFF_CHECK=PASS"
    )

    print(
        "RTL9D3_GATE=PASS"
    )

    print(
        "RTL9D3_COMMIT_ALLOWED=YES"
    )


if __name__ == "__main__":
    main()
