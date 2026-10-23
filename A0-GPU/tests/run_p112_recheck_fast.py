#!/usr/bin/env python3
"""Targeted recheck of inherited P111 tests excluding the known slow base simulator suite.
Report exclusion visibly; never label this a complete inherited rerun.
"""
from pathlib import Path
import concurrent.futures,json,re,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'EVIDENCE'/'P112'
records=json.loads((ROOT/'EVIDENCE'/'P111'/'inherited_module_regression.json').read_text())['results']
files=[r['file'] for r in records if r['file']!='test_a0_regression.py']

def check(name):
    start=time.monotonic()
    try:
        proc=subprocess.run([sys.executable,'-B','-m','unittest','discover','-s',str(ROOT/'A0-GPU'/'tests'),'-p',name],
                            cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
        log,code=proc.stdout,proc.returncode
    except subprocess.TimeoutExpired as exc:
        log=str(exc);code=124
    matches=re.findall(r'Ran (\d+) tests? in',log)
    count=int(matches[-1]) if matches else 0
    (OUT/'fast_modules').mkdir(exist_ok=True)
    (OUT/'fast_modules'/f'{name}.log').write_text(log)
    return {'file':name,'tests':count,'status':'PASS' if code==0 and matches else 'FAIL',
            'exit_code':code,'seconds':round(time.monotonic()-start,2)}

def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as exe:
        results=list(exe.map(check,files))
    count=sum(r['tests'] for r in results)
    expected=sum(r['tests'] for r in records if r['file']!='test_a0_regression.py')
    complete=all(r['status']=='PASS' for r in results) and count==expected
    data={'status':'PASS' if complete else 'PARTIAL_OR_FAIL',
          'qualification':'PARTIAL_INHERITED_REGRESSION_EXCLUDES_BASE_SUITE',
          'excluded':['test_a0_regression.py'],
          'historical_excluded_test_count':59,'rerun_test_count':count,
          'expected_test_count':expected,'results':results}
    (OUT/'inherited_fast_recheck.json').write_text(json.dumps(data,indent=2)+'\n')
    print('P112_33_MODULE_RECHECK',data['status'],count,'/',expected,flush=True)
    for r in results:
        if r['status']!='PASS':print('FAIL',r,flush=True)
    return 0 if complete else 1
if __name__=='__main__':raise SystemExit(main())
