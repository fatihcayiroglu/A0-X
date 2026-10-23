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
HISTORICAL_GATE_VERILATOR_TEST_FLAGS = (
    "-Wno-PROCASSINIT -Wno-MULTIDRIVEN"
)


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
            "command failed rc=" + str(result.returncode) + ": "
            + " ".join(command)
        )
    return result.stdout


def resolve_validated_verilator() -> str:
    configured = os.environ.get(VERILATOR_BIN_ENV)
    requested = configured if configured is not None else "verilator"
    if requested == "":
        raise RuntimeError(
            f"{VERILATOR_BIN_ENV} is set but empty; provide an exact "
            f"Verilator {VALIDATED_VERILATOR_VERSION} executable"
        )
    executable = shutil.which(requested)
    if executable is None:
        detail = (
            "verilator was not found on PATH"
            if configured is None
            else f"{VERILATOR_BIN_ENV} executable was not found: {requested!r}"
        )
        raise RuntimeError(
            f"{detail}; set {VERILATOR_BIN_ENV} to an exact Verilator "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    resolved = Path(executable).resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise RuntimeError(f"Verilator executable is not runnable: {resolved}")
    result = subprocess.run(
        [str(resolved), "--version"],
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    reported = result.stdout.strip()
    if result.returncode:
        raise RuntimeError(
            f"Verilator version check failed rc={result.returncode}: "
            f"{resolved}: {reported}"
        )
    lines = [line.strip() for line in reported.splitlines() if line.strip()]
    fields = lines[0].split() if len(lines) == 1 else []
    actual = (
        fields[1]
        if len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "VERILATOR_TOOLCHAIN_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} "
            f"actual={actual} executable={resolved}; set "
            f"{VERILATOR_BIN_ENV} to an exact Verilator "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    print(f"PRODUCTION_VERILATOR_BIN={resolved}")
    print(f"PRODUCTION_VERILATOR_VERSION={actual}")
    return str(resolved)


def validated_child_environment(verilator_bin: str) -> dict[str, str]:
    selected = Path(verilator_bin).resolve(strict=True)
    if not selected.is_file() or not os.access(selected, os.X_OK):
        raise RuntimeError(f"validated Verilator is not runnable: {selected}")
    child_env = os.environ.copy()
    inherited_test_flags = child_env.get("VERILATOR_TEST_FLAGS")
    if inherited_test_flags not in (None, ""):
        raise RuntimeError(
            "uncontrolled VERILATOR_TEST_FLAGS is not permitted at the "
            f"validated toolchain boundary: {inherited_test_flags!r}"
        )
    child_env.pop("VERILATOR_TEST_FLAGS", None)
    child_env[VERILATOR_BIN_ENV] = str(selected)
    selected_dir = str(selected.parent)
    child_env["PATH"] = selected_dir + os.pathsep + child_env.get("PATH", "")
    literal = shutil.which("verilator", path=child_env["PATH"])
    if literal is None:
        raise RuntimeError(
            "validated child toolchain layout does not expose literal "
            f"verilator beside selected executable: {selected}"
        )
    literal_resolved = Path(literal).resolve(strict=True)
    if literal_resolved != selected:
        raise RuntimeError(
            "validated child Verilator resolution mismatch "
            f"selected={selected} literal={literal_resolved}"
        )
    result = subprocess.run(
        [str(literal_resolved), "--version"],
        cwd=ROOT,
        env=child_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    reported = result.stdout.strip()
    if result.returncode:
        raise RuntimeError(
            f"child Verilator version check failed rc={result.returncode}: "
            f"{literal_resolved}: {reported}"
        )
    lines = [line.strip() for line in reported.splitlines() if line.strip()]
    fields = lines[0].split() if len(lines) == 1 else []
    actual = (
        fields[1]
        if len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "CHILD_VERILATOR_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} actual={actual} "
            f"executable={literal_resolved}"
        )
    print(f"CHILD_VERILATOR_BIN={literal_resolved}")
    print(f"CHILD_VERILATOR_VERSION={actual}")
    print("CHILD_VERILATOR_RESOLUTION=PASS")
    return child_env


def compile_source(path: Path) -> None:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")


def main() -> None:
    targeted_path = ROOT / "tests/run_production_multi_cu_shared_l2.py"
    gate_path = ROOT / "tests/run_production_multi_cu_shared_l2_gate.py"
    compile_source(targeted_path)
    compile_source(gate_path)
    print("PRODUCTION_MULTI_CU_PYTHON_COMPILE=PASS")

    verilator_bin = resolve_validated_verilator()
    child_env = validated_child_environment(verilator_bin)

    with tempfile.TemporaryDirectory(prefix="a0_prod_gate_pycache_") as cache:
        child_env["PYTHONDONTWRITEBYTECODE"] = "1"
        child_env["PYTHONPYCACHEPREFIX"] = cache

        targeted = run([sys.executable, str(targeted_path)], env=child_env)
        if "PRODUCTION_MULTI_CU_SHARED_L2_DRIVER=PASS" not in targeted:
            raise RuntimeError("production targeted driver marker missing")
        print("PRODUCTION_MULTI_CU_TARGETED=PASS")

        regression_env = child_env.copy()
        regression_env["VERILATOR_TEST_FLAGS"] = (
            HISTORICAL_GATE_VERILATOR_TEST_FLAGS
        )
        print("HISTORICAL_GATE_VERILATOR_5050_COMPAT=PASS")
        regression = run(
            [sys.executable, str(ROOT / "tests/run_rtl9d3_gate.py")],
            env=regression_env,
        )
        if "RTL9D3_GATE=PASS" not in regression:
            raise RuntimeError("RTL9D3 recursive gate marker missing")
        print("PRODUCTION_MULTI_CU_RTL9D3_RECURSIVE_GATE=PASS")

    run(["git", "diff", "--check"])
    run(["git", "diff", "--cached", "--check"])
    print("PRODUCTION_MULTI_CU_GIT_DIFF_CHECK=PASS")
    print("PRODUCTION_MULTI_CU_SHARED_L2_GATE=PASS")


if __name__ == "__main__":
    main()
