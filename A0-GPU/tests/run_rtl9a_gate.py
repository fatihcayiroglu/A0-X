#!/usr/bin/env python3
from pathlib import Path
import subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
def run(name,cmd):
    print("\n=== "+name+" ===",flush=True)
    r=subprocess.run(cmd,cwd=ROOT,text=True)
    if r.returncode: raise RuntimeError(f"{name} failed rc={r.returncode}")
    print(name+"=PASS",flush=True)
def main():
    run("RTL9A_PYTHON_COMPILE",[sys.executable,"-m","py_compile",
        "tests/run_rtl9a_memory_boundary.py","tests/run_rtl9a_gate.py"])
    run("RTL9A_MEMORY_SERVICE_BOUNDARY",[sys.executable,"tests/run_rtl9a_memory_boundary.py"])
    run("RTL9A_RTL8C_FULL_REGRESSION",[sys.executable,"tests/run_rtl8c_gate.py"])
    run("RTL9A_GIT_DIFF_CHECK",["git","diff","--check"])
    print("\nRTL9A_GATE=PASS")
    print("RTL9A_COMMIT_ALLOWED=YES")
if __name__=="__main__": main()
