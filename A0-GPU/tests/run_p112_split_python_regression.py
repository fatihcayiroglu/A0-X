#!/usr/bin/env python3
"""Replay inherited modules in isolation without mutating inherited evidence."""
from pathlib import Path
import concurrent.futures,json,re,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'EVIDENCE'/'P112'/'modules'
FILES=[x['file'] for x in json.loads((ROOT/'EVIDENCE'/'P111'/'inherited_module_regression.json').read_text())['results']]

def check(name):
    start=time.monotonic()
    try:
        p=subprocess.run([sys.executable,'-B','-m','unittest','discover',
                          '-s',str(ROOT/'A0-GPU'/'tests'),'-p',name],
                         cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                         text=True,timeout=240)
        log,exit_code=p.stdout,p.returncode
    except subprocess.TimeoutExpired as exc:
        log=str(exc);exit_code=124
    m=re.findall(r'Ran (\d+) tests? in',log)
    count=int(m[-1]) if m else 0
    (OUT/f'{name}.log').write_text(log)
    return {'file':name,'status':'PASS' if exit_code==0 and m else 'FAIL',
            'tests':count,'seconds':round(time.monotonic()-start,2),'exit_code':exit_code}

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as exe:
        results=list(exe.map(check,FILES))
    count=sum(x['tests'] for x in results)
    status='PASS' if len(results)==34 and count==566 and all(x['status']=='PASS' for x in results) else 'FAIL'
    record={'status':status,'module_count':len(results),'test_count':count,
            'qualification':'PYTHON_INHERITED_ONLY_NOT_RTL', 'results':results}
    (OUT.parent/'inherited_module_regression.json').write_text(json.dumps(record,indent=2)+'\n')
    for item in results:
        print(item['status'],item['file'],item['tests'],'tests',item['seconds'],'seconds',flush=True)
    print('P112_INHERITED',status,count,'tests',flush=True)
    return 0 if status=='PASS' else 1

if __name__=='__main__':raise SystemExit(main())
