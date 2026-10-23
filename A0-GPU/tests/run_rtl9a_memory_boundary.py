#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
BOUNDARY=ROOT/"rtl/memory/a0_memory_service_boundary.sv"
L1=ROOT/"rtl/memory/a0_l1_line_cache.sv"
CORE=ROOT/"rtl/core/a0_multi_wave_core.sv"
TB=ROOT/"tests/rtl/a0_memory_service_boundary_tb.sv"
MARKERS=[
"RTL9A_LEGACY_REQUEST_PASSTHROUGH=PASS",
"RTL9A_LEGACY_RESPONSE_PASSTHROUGH=PASS",
"RTL9A_LINE_REQUEST_PASSTHROUGH=PASS",
"RTL9A_LINE_RESPONSE_PASSTHROUGH=PASS",
"RTL9A_DUAL_CHANNEL_INDEPENDENCE=PASS",
"RTL9A_MEMORY_SERVICE_BOUNDARY_TB=PASS",
]
def run(cmd):
    r=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print(r.stdout,end="")
    if r.returncode: raise RuntimeError("command failed: "+" ".join(cmd))
    return r.stdout
def main():
    c=CORE.read_text(); b=BOUNDARY.read_text()
    for tok in ["a0_memory_service_boundary #(","memory_service_boundary (",
                "service_legacy_req_valid","service_legacy_resp_valid",
                "service_mshr_req_valid","service_mshr_resp_valid"]:
        if tok not in c: raise RuntimeError("core integration missing: "+tok)
    if "module a0_memory_service_boundary" not in b:
        raise RuntimeError("boundary module missing")
    with tempfile.TemporaryDirectory(prefix="a0_rtl9a_") as t:
        obj=Path(t)/"obj_dir"
        out=run(["verilator","--binary","--timing","-Wall",
                 "-Werror-PINMISSING","-Werror-WIDTHEXPAND","-Werror-WIDTHTRUNC",
                 "--top-module","a0_memory_service_boundary_tb","--Mdir",str(obj),
                 str(L1),str(BOUNDARY),str(TB)])
        exe=obj/"Va0_memory_service_boundary_tb"
        if not exe.exists(): raise RuntimeError("boundary executable missing")
        out+=run([str(exe)])
    missing=[m for m in MARKERS if m not in out]
    if missing: raise RuntimeError("missing markers: "+", ".join(missing))
    print("RTL9A_MEMORY_SERVICE_BOUNDARY_DRIVER=PASS")
if __name__=="__main__": main()
