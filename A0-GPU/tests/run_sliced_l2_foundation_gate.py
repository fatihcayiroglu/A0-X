#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VALIDATED_VERILATOR_VERSION = "5.050"
VERILATOR_BIN_ENV = "A0_VERILATOR_BIN"


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(
            f"command failed rc={result.returncode}: " + " ".join(command)
        )
    return result.stdout


def resolve_validated_verilator() -> str:
    configured = os.environ.get(VERILATOR_BIN_ENV)
    requested = configured if configured is not None else "verilator"
    if not requested:
        raise RuntimeError(f"{VERILATOR_BIN_ENV} is empty")
    executable = shutil.which(requested)
    if executable is None:
        raise RuntimeError(
            f"set {VERILATOR_BIN_ENV} to exact Verilator "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    resolved = Path(executable).resolve(strict=True)
    result = subprocess.run(
        [str(resolved), "--version"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    fields = result.stdout.strip().split()
    actual = fields[1] if result.returncode == 0 and len(fields) >= 2 and fields[0] == "Verilator" else "UNPARSEABLE"
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "VERILATOR_TOOLCHAIN_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} actual={actual}"
        )
    print(f"SLICED_L2_GATE_VERILATOR_BIN={resolved}")
    print(f"SLICED_L2_GATE_VERILATOR_VERSION={actual}")
    return str(resolved)


def child_environment(verilator_bin: str) -> dict[str, str]:
    selected = Path(verilator_bin).resolve(strict=True)
    env = os.environ.copy()
    env[VERILATOR_BIN_ENV] = str(selected)
    env["PATH"] = str(selected.parent) + os.pathsep + env.get("PATH", "")
    literal = shutil.which("verilator", path=env["PATH"])
    if literal is None or Path(literal).resolve(strict=True) != selected:
        raise RuntimeError("validated child Verilator resolution mismatch")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    print("SLICED_L2_CHILD_VERILATOR_RESOLUTION=PASS")
    return env


def compile_python(path: Path) -> None:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")


def main() -> None:
    targeted = ROOT / "tests/run_sliced_l2_foundation.py"
    production_gate = ROOT / "tests/run_production_multi_cu_shared_l2_gate.py"
    compile_python(targeted)
    compile_python(Path(__file__).resolve())
    compile_python(production_gate)
    print("SLICED_L2_GATE_PYTHON_COMPILE=PASS")

    verilator_bin = resolve_validated_verilator()
    env = child_environment(verilator_bin)

    with tempfile.TemporaryDirectory(prefix="a0_sliced_l2_gate_pycache_") as cache:
        env["PYTHONPYCACHEPREFIX"] = cache

        targeted_output = run([sys.executable, str(targeted)], env=env)
        if "SLICED_L2_FOUNDATION_DRIVER=PASS" not in targeted_output:
            raise RuntimeError("sliced-L2 targeted driver marker missing")
        print("SLICED_L2_TARGETED_GATE=PASS")

        regression_output = run([sys.executable, str(production_gate)], env=env)
        if "PRODUCTION_MULTI_CU_SHARED_L2_GATE=PASS" not in regression_output:
            raise RuntimeError("production multi-CU recursive gate marker missing")
        print("SLICED_L2_PRODUCTION_MULTI_CU_RECURSIVE_GATE=PASS")

    run(["git", "diff", "--check"])
    run(["git", "diff", "--cached", "--check"])
    print("SLICED_L2_GIT_DIFF_CHECK=PASS")
    print("SLICED_L2_FOUNDATION_GATE=PASS")


if __name__ == "__main__":
    main()
