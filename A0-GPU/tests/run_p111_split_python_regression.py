#!/usr/bin/env python3
"""Re-run inherited P110 unittest modules in isolated processes."""
from pathlib import Path
import concurrent.futures
import json
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
EVIDENCE=ROOT/'EVIDENCE'/'P111'
FILES=[x['file'] for x in json.loads((ROOT/'EVIDENCE'/'P110'/'inherited_module_regression.json').read_text())['results']]

def check(name):
    start=time.monotonic()
    p=subprocess.run([sys.executable,'-m','unittest','discover','-s',str(ROOT/'A0-GPU'/'tests'),
                      '-p',name], cwd=ROOT, stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                     text=True,timeout=240)
    m=re.findall(r'Ran (\d+) tests? in',p.stdout)
    n=int(m[-1]) if m else 0
    (EVIDENCE/'modules'/f'{name}.log').write_text(p.stdout)
    return {'file':name,'status':'PASS' if p.returncode==0 and m else 'FAIL',
            'tests':n,'seconds':round(time.monotonic()-start,2),
            'exit_code':p.returncode}

def main():
    (EVIDENCE/'modules').mkdir(parents=True,exist_ok=True)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as exe:
            results=list(exe.map(check,FILES))
    except Exception as exc:
        print('P111_INHERITED_TEST_EXECUTION_FAILED',type(exc).__name__,exc)
        return 1
    count=sum(x['tests'] for x in results)
    status='PASS' if all(x['status']=='PASS' for x in results) and count==566 else 'FAIL'
    record={'status':status,'module_count':len(results),'test_count':count,
            'qualification':'INHERITED_PYTHON_TESTS_ONLY', 'results':results}
    (EVIDENCE/'inherited_module_regression.json').write_text(json.dumps(record,indent=2)+'\n')
    for r in results:
        print(r['status'],r['file'],r['tests'],'tests',r['seconds'],'s',flush=True)
    print('P111_INHERITED',status,count,'tests',flush=True)
    return 0 if status=='PASS' else 1
if __name__=='__main__':raise SystemExit(main())
