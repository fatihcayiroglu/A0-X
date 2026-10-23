#!/usr/bin/python3
"""External, opt-in validation support. Importing this module performs no work.

Example (run under native WSL; do not run concurrent jobs in one context)::

    with Qualification(label="p29-replay") as q:
        q.bootstrap()
        q.run_canonical(29)

For an external test, call build_simulation(top, source_paths, name="repro"),
then run([binary], "repro_sim", timeout=120). A nonzero simulation is a failure,
including an intentionally reproducing test: its raw output and return code are
retained, and no passing milestone is inferred from a historical receipt.

The checkpoint snapshot is taken on entry and checked on every normal/Python
exception/SIGTERM exit. SIGKILL or host loss cannot execute a finally block; the
persisted before snapshot supports a subsequent independent containment audit.
"""
from __future__ import annotations

from dataclasses import dataclass
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Sequence

sys.dont_write_bytecode = True
if sys.flags.optimize or os.environ.get('PYTHONOPTIMIZE'):
    raise SystemExit('PYTHON_OPTIMIZATION_FORBIDDEN')


DEFAULT_CHECKPOINT = Path("/tmp/a0_p30_checkpoint_a1yyhaws")
EXACT_VERSION = "Verilator 5.050 2026-07-01 rev v5.050"
TAR_SHA = "55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451"
OUTER_SHA = "03bd901f94adf465a0bbf2b688408d9a384a56183e99ec3480a037e0eed2fd67"
INNER_SHA = "270d17005174e8133cabe11ad9f62a7b5e43989abfde6e4217d0792df39a2f79"
STRICT_FLAGS = ("--timing", "--unroll-count", "512", "-Wall",
                "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def snapshot_tree(root: Path) -> dict:
    """Record every path, file content, symlink target, and permission/type bits.

    Include directories and .git/index; omit atime/mtime, which reads and native
    extraction can alter without changing the protected content or permissions.
    Do not follow symlinks when walking the checkpoint.
    """
    records = {}
    pending = [root]
    while pending:
        path = pending.pop()
        info = path.lstat()
        row = {"mode": stat.S_IMODE(info.st_mode), "type": stat.S_IFMT(info.st_mode)}
        if stat.S_ISDIR(info.st_mode):
            pending.extend(sorted(path.iterdir(), reverse=True))
        elif stat.S_ISREG(info.st_mode):
            row.update(size=info.st_size, sha256=sha256(path))
        elif stat.S_ISLNK(info.st_mode):
            row["target"] = os.readlink(path)
        else:
            raise RuntimeError("UNSUPPORTED_CHECKPOINT_NODE:" + str(path))
        records[path.relative_to(root).as_posix()] = row
    return dict(sorted(records.items()))


def tree_changes(before: dict, after: dict) -> dict:
    return {"added": sorted(after.keys() - before.keys()),
            "removed": sorted(before.keys() - after.keys()),
            "changed": sorted(k for k in before.keys() & after.keys() if before[k] != after[k])}


class ValidationFailure(RuntimeError):
    def __init__(self, stage: str, detail: str, rc: int = 1):
        self.stage, self.detail, self.rc = stage, detail, rc
        super().__init__(stage + ": " + detail)


@dataclass(frozen=True)
class CommandResult:
    command: tuple[str, ...]
    rc: int
    log: Path
    metadata: Path
    elapsed_seconds: float

    @property
    def stdout(self) -> str:
        return self.log.read_text(encoding="utf-8", errors="replace")


class Qualification:
    """One owned /tmp work area, one toolchain, serialized commands, full audit."""

    def __init__(self, checkpoint: Path = DEFAULT_CHECKPOINT, *, label: str = "validation"):
        self.checkpoint = Path(checkpoint).resolve(strict=True)
        self.repo = self.checkpoint / "A0-GPU"
        self.label = re.sub(r"[^A-Za-z0-9_-]", "_", label)
        self.work: Path | None = None
        self.env: dict[str, str] = {}
        self._sequence = 0
        self._first_failure = None
        self._active = None
        self._ready = False
        self._strict_verified = False
        self._old_sigterm = None
        self.secondary_errors = []

    def _json(self, name: str, value: object) -> Path:
        path = self.work / name
        with path.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        return path

    def _remember(self, error: BaseException) -> None:
        if self._first_failure is None:
            self._first_failure = {"stage": getattr(error, "stage", "EXCEPTION"),
                                   "detail": getattr(error, "detail", str(error)),
                                   "rc": getattr(error, "rc", 1),
                                   "exception_type": type(error).__name__}
            try:
                self._json("first-failure.json", self._first_failure)
            except BaseException as secondary:
                self.secondary_errors.append('FIRST_FAILURE_RECORD:' + repr(secondary))

    def fail(self, stage: str, detail: str, rc: int = 1):
        error = ValidationFailure(stage, detail, rc)
        self._remember(error)
        raise error

    def __enter__(self):
        if os.name != "posix" or not self.repo.is_dir():
            raise RuntimeError("NATIVE_LINUX_CHECKPOINT_REQUIRED")
        self.before = snapshot_tree(self.checkpoint)
        self.helper_before = sha256(Path(__file__))
        self.index_before = (self.repo / ".git/index").read_bytes()
        self.work = Path(tempfile.mkdtemp(prefix="a0_p30_" + self.label + "_", dir="/tmp")).resolve()
        if self.work == self.checkpoint or self.checkpoint in self.work.parents:
            raise RuntimeError("WORK_AREA_INSIDE_CHECKPOINT")
        self._json("checkpoint-before.json", self.before)
        with (self.work / "index-before.raw").open("xb") as stream:
            stream.write(self.index_before)
        self._json("owner.json", {"pid": os.getpid(), "uid": os.getuid(),
                                 "checkpoint": str(self.checkpoint), "label": self.label})
        self._old_sigterm = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, self._on_sigterm)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:
            self.fail('PROCESS_LIFECYCLE', 'SUBREAPER_SETUP_FAILED')
        print("VALIDATION_WORK=" + str(self.work), flush=True)
        return self

    def _on_sigterm(self, signum, frame):
        raise ValidationFailure("INTERRUPTED", "SIGTERM", 128 + signum)

    @staticmethod
    def _stop_group(proc: subprocess.Popen) -> dict:
        group = proc.pid
        if group <= 1 or group == os.getpgrp():
            raise RuntimeError('UNSAFE_PROCESS_GROUP')
        lifecycle = dict(process_group=group, signals=[], adopted_reaped=[])
        saved = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}
        def exists():
            try:
                os.killpg(group, 0)
                return True
            except ProcessLookupError:
                return False
        def reap():
            if proc.poll() is None:
                return
            while True:
                try:
                    pid, status = os.waitpid(-group, os.WNOHANG)
                except ChildProcessError:
                    return
                if pid == 0:
                    return
                lifecycle['adopted_reaped'].append([pid, status])
        try:
            for sig in saved:
                signal.signal(sig, signal.SIG_IGN)
            reap()
            lifecycle['group_existed_after_wait'] = exists()
            for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 8)):
                if exists():
                    try:
                        os.killpg(group, sig)
                        lifecycle['signals'].append(int(sig))
                    except ProcessLookupError:
                        pass
                end = time.monotonic() + grace
                while exists() and time.monotonic() < end:
                    reap()
                    time.sleep(0.02)
            proc.wait(timeout=1)
            reap()
            lifecycle['group_gone'] = not exists()
            if not lifecycle['group_gone']:
                raise RuntimeError('OWNED_PROCESS_GROUP_SURVIVED')
            return lifecycle
        finally:
            for sig, handler in saved.items():
                signal.signal(sig, handler)

    def __exit__(self, exc_type, exc, traceback):
        late_error = None
        try:
            if exc is not None:
                self._remember(exc)
            if self._active is not None:
                self._stop_group(self._active)
                self._active = None
            if self._ready and not self._strict_verified:
                try:
                    self.assert_strict(minimum_elaborations=0 if exc is not None else 1)
                except BaseException as error:
                    self.secondary_errors.append('STRICT_EXIT_AUDIT:' + repr(error))
                    self._remember(error)
                    late_error = error
        finally:
            for name, check in (
                ('helper_identity', lambda: sha256(Path(__file__)) == self.helper_before),
                ('toolchain_identity', lambda: self.verify_toolchain() is None if self._ready else True),
            ):
                try:
                    if not check():
                        raise ValidationFailure('CONTAINMENT', name)
                except BaseException as error:
                    self.secondary_errors.append(name + ':' + repr(error))
                    self._remember(error)
                    late_error = late_error or error
            try:
                after = snapshot_tree(self.checkpoint)
                changes = tree_changes(self.before, after)
                index_unchanged = (self.repo / ".git/index").read_bytes() == self.index_before
                unchanged = not any(changes.values()) and index_unchanged
                if not unchanged:
                    error = ValidationFailure("CONTAINMENT", json.dumps(changes) +
                                              "; raw_index_identical=" + str(index_unchanged))
                    self.secondary_errors.append('CONTAINMENT_EXIT_AUDIT:' + repr(error))
                    self._remember(error)
                    late_error = late_error or error
                for name, record in (("checkpoint-after.json", after),
                                     ("containment.json", {"unchanged": unchanged,
                                      "raw_index_identical": index_unchanged, **changes})):
                    try:
                        self._json(name, record)
                    except BaseException as error:
                        self.secondary_errors.append('AUDIT_RECORD:' + repr(error))
                        self._remember(error)
                        late_error = late_error or error
            except BaseException as error:
                self.secondary_errors.append('CONTAINMENT_EXIT_AUDIT:' + repr(error))
                self._remember(error)
                late_error = late_error or error
            finally:
                signal.signal(signal.SIGTERM, self._old_sigterm)
                try:
                    self._json("summary.json", {"strict_verified": self._strict_verified,
                                "first_failure": self._first_failure,
                                "secondary_errors": self.secondary_errors,
                                "checkpoint": str(self.checkpoint), "work": str(self.work)})
                except BaseException as error:
                    self.secondary_errors.append('SUMMARY_RECORD:' + repr(error))
                    self._remember(error)
                    late_error = late_error or error
                if self._first_failure is not None:
                    print("VALIDATION_FIRST_FAILURE=" + json.dumps(self._first_failure), flush=True)
        if exc is None and late_error is not None:
            raise late_error
        return False

    def _extract_toolchain(self, source: Path, destination: Path) -> dict:
        """Extract validated dirs/files first, then simple contained symlinks.

        The pinned archive has 363 regular files, 55 dirs, and 7 basename-only
        library symlinks. Hardlinks/devices/FIFOs and ambiguous members fail.
        """
        with tarfile.open(source, "r:gz") as archive:
            members = archive.getmembers()
            by_name = {}
            for member in members:
                path = PurePosixPath(member.name)
                if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                        or ":" in member.name or not path.parts or path.parts[0] != "verilator"
                        or str(path) in by_name or not (member.isdir() or member.isfile() or member.issym())
                        or member.mode & 0o7000):
                    self.fail("ARCHIVE_ENTRIES", "UNSAFE_MEMBER:" + member.name)
                by_name[str(path)] = member
                if member.issym():
                    link = PurePosixPath(member.linkname)
                    if (link.is_absolute() or len(link.parts) != 1 or link.name in ("", ".", "..")
                            or "\\" in member.linkname or ":" in member.linkname):
                        self.fail("ARCHIVE_ENTRIES", "UNSAFE_SYMLINK:" + member.name)
            for name, member in by_name.items():
                for ancestor in PurePosixPath(name).parents:
                    if str(ancestor) in by_name and not by_name[str(ancestor)].isdir():
                        self.fail("ARCHIVE_ENTRIES", "NON_DIRECTORY_ANCESTOR:" + name)
                if member.issym():
                    target = str(PurePosixPath(name).parent / member.linkname)
                    if target not in by_name or not by_name[target].isfile():
                        self.fail("ARCHIVE_ENTRIES", "NON_FILE_SYMLINK_TARGET:" + name)
            for name, member in by_name.items():
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                if member.isdir():
                    target.mkdir(exist_ok=True)
                elif member.isfile():
                    with archive.extractfile(member) as incoming, target.open("xb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
                    os.chmod(target, member.mode & 0o777)
            for name, member in by_name.items():
                if member.issym():
                    (destination / name).symlink_to(member.linkname)
            for name, member in sorted(by_name.items(), key=lambda row: len(row[0]), reverse=True):
                if member.isdir():
                    os.chmod(destination / name, member.mode & 0o777)
            return {"members": len(members),
                    "files": sum(m.isfile() for m in members),
                    "directories": sum(m.isdir() for m in members),
                    "symlinks": sum(m.issym() for m in members)}

    def bootstrap(self) -> None:
        if self._ready:
            self.fail("BOOTSTRAP", "ALREADY_BOOTSTRAPPED")
        sources = self.checkpoint / "TOOLCHAIN"
        archive = sources / "verilator-manylinux2014_x86_64-5.050.tar.gz"
        outer_source = sources / "strict-all-outer-verilator.py"
        inner_source = sources / "strict-all-inner-verilator_bin.py"
        for path, expected in ((archive, TAR_SHA), (outer_source, OUTER_SHA), (inner_source, INNER_SHA)):
            if sha256(path) != expected:
                self.fail("TOOLCHAIN_PROVENANCE", "SHA256_MISMATCH:" + str(path))
        self.install = self.work / "toolchain"
        self.install.mkdir(mode=0o700)
        archive_info = self._extract_toolchain(archive, self.install)
        self.tool = self.install / "verilator"
        self.real = self.tool / "bin/verilator"
        self.inner = self.tool / "bin/verilator_bin"
        self.binary = self.tool / "bin/verilator_bin.real"
        binary_sha, frontend_sha = sha256(self.inner), sha256(self.real)
        # Both paths are in this freshly created, verified, owned toolchain.
        self.inner.rename(self.binary)
        shutil.copyfile(inner_source, self.inner)
        os.chmod(self.inner, 0o755)
        self.outer = self.work / "strict-all-outer-verilator.py"
        shutil.copyfile(outer_source, self.outer)
        os.chmod(self.outer, 0o755)
        self.identities = {str(self.binary): binary_sha, str(self.real): frontend_sha,
                           str(self.inner): INNER_SHA, str(self.outer): OUTER_SHA}
        self.outer_log = self.work / "strict-outer.jsonl"
        self.inner_log = self.work / "strict-inner.jsonl"
        self.env = self._sanitized_env()
        self._json("toolchain-provenance.json", {"archive": str(archive), "archive_sha256": TAR_SHA,
                   "extracted": archive_info, "identities": self.identities,
                   "manifest_sha256": sha256(sources / "manifest-manylinux2014_x86_64.json")})
        self._json("strict-policy.json", {
            "verilator_warning_suppressions_allowed": False,
            "outer_argv_and_VERILATOR_TEST_FLAGS_instrumented": True,
            "real_verilator_bin_boundary_instrumented": True,
            "stripped_arguments_must_equal_zero": True,
            "compiler_generated_CXX_Wno_flags_are_not_RTL_suppressions": True,
            "version_required": EXACT_VERSION,
            "generated_builds_are_split_and_make_jobs": 1,
            "missing_empty_or_malformed_instrumentation_logs_are_failure": True})
        self._ready = True
        result = self.run([self.outer, "--version"], "version", timeout=30, reject_diagnostics=True)
        if result.stdout.strip() != EXACT_VERSION:
            self.fail("VERSION", repr(result.stdout.strip()))
        self.verify_toolchain()

    def _sanitized_env(self) -> dict[str, str]:
        env = os.environ.copy()
        drop = {"BASH_ENV", "ENV", "LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
                "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONOPTIMIZE",
                "PERL5LIB", "PERL5OPT", "CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS",
                "LDFLAGS", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "MAKEFILES",
                "GNUMAKEFLAGS", "CDPATH", "TMPDIR", "TEMP", "TMP"}
        for key in list(env):
            if key in drop or key.startswith(("VERILATOR", "A0_", "GIT_", "BASH_FUNC_")):
                env.pop(key)
        env.update(PATH="/usr/local/bin:/usr/bin:/bin", LANG="C", LC_ALL="C",
                   PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1",
                   A0_REAL_VERILATOR_5050=str(self.real), A0_VERILATOR_BIN=str(self.outer),
                   A0_STRICT_OUTER_LOG=str(self.outer_log), A0_STRICT_INNER_LOG=str(self.inner_log),
                   LD_LIBRARY_PATH=str(self.tool / "lib64"),
                   GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_COUNT="1",
                   GIT_CONFIG_KEY_0="diff.autoRefreshIndex", GIT_CONFIG_VALUE_0="false")
        return env

    def verify_toolchain(self) -> None:
        for name, expected in self.identities.items():
            if sha256(Path(name)) != expected:
                self.fail("TOOLCHAIN_IDENTITY", name)

    def run(self, command: Sequence[object], stage: str, *, timeout: float = 600,
            cwd: Path | None = None, reject_diagnostics: bool = False) -> CommandResult:
        if not self._ready or self._active is not None:
            self.fail(stage, "BOOTSTRAP_REQUIRED_OR_CONCURRENT_COMMAND")
        if self._first_failure is not None:
            raise ValidationFailure(self._first_failure['stage'], self._first_failure['detail'],
                                    self._first_failure['rc'])
        self._strict_verified = False
        self._sequence += 1
        stem = f"{self._sequence:03d}_" + re.sub(r"[^A-Za-z0-9_-]", "_", stage)
        log = self.work / (stem + ".log")
        metadata = self.work / (stem + ".json")
        argv = tuple(str(x) for x in command)
        command_cwd = Path(cwd or self.repo).resolve(strict=True)
        if not argv or timeout <= 0:
            self.fail(stage, "INVALID_COMMAND_OR_TIMEOUT")
        started = time.monotonic()
        timed_out, interrupted, rc = False, False, None
        lifecycle = {}
        primary = None
        try:
            with log.open("xb") as output:
                self._active = subprocess.Popen(argv, cwd=command_cwd, env=self.env,
                                               stdout=output, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                try:
                    rc = self._active.wait(timeout=timeout)
                    if rc != 0:
                        primary = ValidationFailure(stage, 'RC=' + str(rc) + '; raw_log=' + str(log), rc)
                        self._remember(primary)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    primary = ValidationFailure(stage, 'TIMEOUT; raw_log=' + str(log), 124)
                    self._remember(primary)
                except BaseException as error:
                    interrupted = True
                    primary = error if isinstance(error, ValidationFailure) else ValidationFailure(
                        stage, repr(error), 130 if isinstance(error, KeyboardInterrupt) else 1)
                    self._remember(primary)
                finally:
                    try:
                        lifecycle = self._stop_group(self._active)
                        rc = self._active.returncode
                        if lifecycle['group_existed_after_wait'] and primary is None:
                            primary = ValidationFailure('PROCESS_LIFECYCLE', 'CHILD_LEFT_LIVE_DESCENDANTS')
                            self._remember(primary)
                    except BaseException as error:
                        self.secondary_errors.append('PROCESS_CLEANUP:' + repr(error))
                        if primary is None:
                            primary = ValidationFailure('PROCESS_LIFECYCLE', repr(error))
                            self._remember(primary)
        except BaseException as error:
            if primary is None:
                primary = error if isinstance(error, ValidationFailure) else ValidationFailure(stage, repr(error), 127)
                self._remember(primary)
            else:
                self.secondary_errors.append('LOG_CLOSE_OR_EXECUTION:' + repr(error))
        finally:
            self._active = None
            elapsed = time.monotonic() - started
            try:
                self._json(metadata.name, {"command": argv, "cwd": str(command_cwd),
                       "raw_log": str(log), "rc": rc, "timeout_seconds": timeout,
                       "timed_out": timed_out, "interrupted": interrupted,
                       "lifecycle": lifecycle, "raw_log_sha256": sha256(log) if log.exists() else None,
                       "elapsed_seconds": elapsed})
            except BaseException as error:
                self.secondary_errors.append('COMMAND_METADATA:' + repr(error))
                if primary is None:
                    primary = ValidationFailure('COMMAND_METADATA', repr(error))
                    self._remember(primary)
        if primary is not None:
            raise primary
        result = CommandResult(argv, rc, log, metadata, elapsed)
        if timed_out:
            self.fail(stage, "TIMEOUT; raw_log=" + str(log) + "; process_rc=" + str(rc), 124)
        if rc != 0:
            self.fail(stage, "RC=" + str(rc) + "; raw_log=" + str(log), rc)
        if reject_diagnostics and re.search(r'(?im)%Warning|%Error|\bwarning:', result.stdout):
            self.fail(stage, "VERILATOR_DIAGNOSTIC; raw_log=" + str(log), 2)
        self.verify_toolchain()
        if snapshot_tree(self.checkpoint) != self.before:
            self.fail('CONTAINMENT', 'CHECKPOINT_CHANGED_BETWEEN_COMMANDS')
        return result

    def verilator(self, arguments: Sequence[object], stage: str, *, timeout: float = 600) -> CommandResult:
        args = [str(x) for x in arguments]
        if any(x.startswith("-Wno-") or x in ("--build", "--binary") for x in args):
            self.fail(stage, "SUPPRESSION_OR_OVERLAPPED_BUILD_REQUESTED")
        return self.run([self.outer, *args], stage, timeout=timeout, reject_diagnostics=True)

    def build_simulation(self, top: str, sources: Sequence[Path], *, name: str = "simulation",
                         parameters: Sequence[str] = (), timeout: float = 600) -> Path:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", top) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            self.fail("BUILD_ARGUMENTS", "INVALID_TOP_OR_NAME")
        obj = self.work / (name + "_obj")
        if obj.exists():
            self.fail("BUILD_ARGUMENTS", "OBJECT_DIRECTORY_ALREADY_EXISTS:" + str(obj))
        paths = [Path(p).resolve(strict=True) for p in sources]
        self.verilator([*STRICT_FLAGS, "--cc", "--exe", "--main", "--top-module", top,
                        "--Mdir", obj, *parameters, *paths], name + "_generate", timeout=timeout)
        # The preceding synchronous command has exited before make starts.
        self.run(["/usr/bin/make", "-C", obj, "-f", "V" + top + ".mk", "-j1"],
                 name + "_make", timeout=timeout)
        binary = obj / ("V" + top)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            self.fail(name + "_make", "SIMULATOR_NOT_EXECUTABLE:" + str(binary))
        return binary

    def _strict_rows(self, path: Path, *, outer: bool) -> list[dict]:
        if not path.is_file() or path.stat().st_size == 0:
            self.fail("STRICT_LOG", "MISSING_OR_EMPTY:" + str(path))
        rows = []
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            try:
                row = json.loads(line)
                required = ("original", "forwarded", "stripped") + (("env_stripped",) if outer else ())
                if not isinstance(row, dict) or any(not isinstance(row.get(k), list) for k in required):
                    raise ValueError("INVALID_ROW_SCHEMA")
                if any(not isinstance(a, str) for k in required for a in row[k]):
                    raise ValueError("NON_STRING_ARGUMENT")
            except (ValueError, TypeError) as error:
                self.fail("STRICT_LOG", f"{path}:{number}:{error}")
            if (row["stripped"] or row.get("env_stripped") or row["original"] != row["forwarded"]
                    or any(a.startswith("-Wno-") for a in row["forwarded"])):
                self.fail("STRICT_LEAK", f"{path}:{number}")
            rows.append(row)
        return rows

    def assert_strict(self, *, minimum_elaborations: int = 1) -> dict:
        self.verify_toolchain()
        outer = self._strict_rows(self.outer_log, outer=True)
        inner = self._strict_rows(self.inner_log, outer=False)
        elaborations = lambda rows: sum("--lint-only" in r["forwarded"] or "--cc" in r["forwarded"] for r in rows)
        outer_elab, inner_elab = elaborations(outer), elaborations(inner)
        if outer_elab < minimum_elaborations or inner_elab < minimum_elaborations or outer_elab != inner_elab:
            self.fail("STRICT_REAL_CALLS", f"outer_elaborations={outer_elab}; inner_elaborations={inner_elab}")
        report = {"outer_calls": len(outer), "inner_calls": len(inner),
                  "outer_elaborations": outer_elab, "inner_elaborations": inner_elab,
                  "outer_stripped_count": 0, "inner_stripped_count": 0}
        self._sequence += 1
        self._json(f"{self._sequence:03d}_strict-verification.json", report)
        self._strict_verified = True
        return report

    def run_canonical(self, milestone: int = 29, *, timeout: float = 3000) -> CommandResult:
        if milestone not in (27, 28, 29):
            self.fail("CANONICAL_ARGUMENT", "SUPPORTED_UNCHANGED_RUNNERS_ARE_P27_P28_P29")
        script = self.repo / "tests" / f"run_prod_seam_p{milestone}.py"
        result = self.run(["/usr/bin/python3", "-u", script], f"p{milestone}_canonical",
                          timeout=timeout, reject_diagnostics=True)
        required = f"PROD_SEAM_P{milestone}_GATE=PASS"
        if required not in result.stdout.splitlines():
            self.fail("CANONICAL_MARKER", "ABSENT:" + required)
        self.assert_strict(minimum_elaborations=4)
        return result


if __name__ == "__main__":
    raise SystemExit("Import Qualification from this reviewed helper; execution requires an explicit calling script.")
