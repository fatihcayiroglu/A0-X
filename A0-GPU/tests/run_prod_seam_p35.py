#!/usr/bin/python3
"""P35 cache-backed atomics / unique retirement canonical qualification.

This gate runs in a native isolated P34-derived checkpoint, never live. Its
external bounded supervisor owns live/frozen-artifact containment. A gate PASS
is not CLOSED; independent packaging/readback must subsequently succeed.
"""
import sys
sys.dont_write_bytecode=True
import argparse,json,os,re,resource,shutil
from pathlib import Path
from types import SimpleNamespace
from p34_validation_support import Qualification,STRICT_FLAGS,EXACT_VERSION,sha256
import run_prod_seam_p34 as p34
import p35_fresh_p34_audit as audit34
import run_p35_dedup_mutation as mutation
from p35_behavior_contract import parse_behavior

ROOT=Path(__file__).resolve().parents[1]
CTRL='a0_cache_backed_atomic_controller'
GUARD='a0_atomic_response_retire_guard'
RAW='a0_production_atomic_coherent_progress_subsystem'
TOP='a0_production_atomic_retiring_subsystem'
NEW_RTL=(CTRL,RAW,GUARD,TOP)
PHASES={'component':CTRL,'retire':GUARD,'integrated':RAW,'retiring':TOP}
SOURCE_NAMES=tuple(['rtl/memory/'+name+'.sv' for name in NEW_RTL]
    +['tests/rtl/'+name+'_tb.sv' for name in NEW_RTL]
    +['docs/architecture/A0_PROD_SEAM_P35_ATOMICS_CONTRACT.md','tests/p35_behavior_contract.py',
      'tests/p35_fresh_p34_audit.py','tests/run_p35_dedup_mutation.py',
      'tests/fixtures/p35_no_commit_dedup/'+CTRL+'.sv','tests/run_prod_seam_p35.py'])
STRICT={'outer_calls':16,'inner_calls':64,'outer_elaborations':15,'inner_elaborations':15,
        'outer_stripped_count':0,'inner_stripped_count':0}
CLEAN={'added':[],'changed':[],'removed':[],'unchanged':True,'raw_index_identical':True}


def ensure(q,ok,detail):
    if not ok:q.fail('P35_CONTRACT',detail)


def read_json(path):return json.loads(Path(path).read_text())


def own_sources():return {name:sha256(ROOT/name) for name in SOURCE_NAMES}


def frozen_guard(q):
    ensure(q,sha256(ROOT/'tests/p34_validation_support.py')==p34.SUPPORT_SHA,'FROZEN_P34_SUPPORT')
    ensure(q,sha256(ROOT.parent/audit34.P34_RECEIPT)==audit34.P34_RECEIPT_SHA,'FROZEN_P34_CANONICAL_RECEIPT')
    receipt=read_json(ROOT.parent/audit34.P34_RECEIPT)
    ensure(q,p34.own_sources()==receipt['completed_stages']['p34_source_sha256'],'FROZEN_P34_SOURCE_IDENTITY')
    return p34.frozen_guard(q)


def rtl_sources():
    return [ROOT/'rtl/memory'/name for name in (*p34.FROZEN_RTL,*p34.NEW_RTL)]


def selected_sources(phase):
    if phase in ('component','retire'):selected=[ROOT/'rtl/memory'/(PHASES[phase]+'.sv')]
    else:selected=rtl_sources()+[ROOT/'rtl/memory'/(name+'.sv') for name in
        ((CTRL,RAW) if phase=='integrated' else NEW_RTL)]
    return [*selected,ROOT/'tests/rtl'/(PHASES[phase]+'_tb.sv')]


def lint_parameters(variant):
    return [f'-GCLIENT_COUNT={1<<variant}',f'-GSLICE_COUNT={1<<variant}',
        f'-GLINE_WORDS={1<<variant}',f'-GSET_COUNT_PER_SLICE={1<<variant}',
        f'-GATOMIC_ENTRY_COUNT={2<<variant}',f'-GATOMIC_GENERATION_W={variant+1}',
        f'-GCOHERENCE_GEN_W={variant+1}']


def exact_commands(q,commands,work,work_root):
    outer=str(work/'strict-all-outer-verilator.py')
    expected=[('version',[outer,'--version'],ROOT,30)]
    def git(phase):
        for suffix,args in (('head',['rev-parse','HEAD']),('branch',['branch','--show-current']),
            ('diffcheck',['diff','--check']),('diff',['diff','--binary']),
            ('staged',['diff','--cached','--name-status']),('index_semantics',['ls-files','--stage','-z'])):
            expected.append((phase+'_git_'+suffix,['/usr/bin/git','-c','diff.autoRefreshIndex=false',*args],ROOT,30))
    git('pre')
    for variant in range(3):
        name='lint_'+str(variant)
        expected.append((name,[outer,*STRICT_FLAGS,'--lint-only','--top-module',TOP,'--Mdir',str(work/name),
            *lint_parameters(variant),*(str(p) for p in rtl_sources()),
            *(str(ROOT/'rtl/memory'/(n+'.sv')) for n in NEW_RTL)],ROOT,600))
    for phase,top_name in PHASES.items():
        for variant in range(3):
            name=phase+'_'+str(variant);top=top_name+'_tb';obj=work/(name+'_obj')
            expected.extend([(name+'_generate',[outer,*STRICT_FLAGS,'--cc','--exe','--main','--top-module',top,
                '--Mdir',str(obj),f'-GVARIANT={variant}',*(str(p) for p in selected_sources(phase))],ROOT,600),
                (name+'_make',['/usr/bin/make','-C',str(obj),'-f','V'+top+'.mk','-j1'],ROOT,600),
                (name+'_sim',[str(obj/('V'+top))],work,180)])
    expected.append(('dedup_mutation',['/usr/bin/python3','-B','-u',str(ROOT/'tests/run_p35_dedup_mutation.py'),
        '--work-root',str(work_root)],ROOT,1800))
    expected.append(('p34_canonical',['/usr/bin/python3','-B','-u',str(ROOT/'tests/run_prod_seam_p34.py'),
        '--work-root',str(work_root)],ROOT,6000))
    git('post')
    ensure(q,len(expected)==54 and set(commands)=={f'{i:03d}_{name}.log' for i,(name,_,_,_) in enumerate(expected,1)},
        'EXACT_54_COMMAND_SEQUENCE')
    for number,(name,argv,cwd,timeout) in enumerate(expected,1):
        row=commands[f'{number:03d}_{name}.log'];meta=read_json(row['metadata'])
        ensure(q,row['command']==argv and meta['command']==argv and meta['cwd']==str(cwd)
            and meta['timeout_seconds']==timeout,'EXACT_COMMAND_CWD_TIMEOUT:'+name)
    return expected


def one_value(q,text,prefix):
    values=[line.removeprefix(prefix) for line in text.splitlines() if line.startswith(prefix)]
    ensure(q,len(values)==1,'EXACT_ONE_VALUE:'+prefix)
    return values[0]


def mutation_result(q,row,work_root):
    ensure(q,row.stdout.splitlines().count('P35_EXPECTED_DEDUP_MUTATION=DETECTED')==1,'MUTATION_DETECTION_MARKER')
    work=Path(one_value(q,row.stdout,'VALIDATION_WORK='))
    ensure(q,work.parent==work_root and work!=q.work,'SEPARATE_NEGATIVE_DOMAIN')
    receipt=Path(one_value(q,row.stdout,'P35_MUTATION_RECEIPT='))
    ensure(q,receipt==work/'mutation-detection-receipt.json' and sha256(receipt)==
        one_value(q,row.stdout,'P35_MUTATION_RECEIPT_SHA256='),'NEGATIVE_RECEIPT_BINDING')
    good,bad,tb=mutation.sources()
    pins={str(p):sha256(p) for p in (good,bad,tb,ROOT/'tests/run_p35_dedup_mutation.py')}
    actual=mutation.audit_mutation(work,q.before,q.index_before,pins)
    ensure(q,read_json(receipt)==actual,'NEGATIVE_INDEPENDENT_RAW_REAUDIT')
    return {'work':str(work),'receipt':str(receipt),'receipt_sha256':sha256(receipt),
        'raw_log':str(row.log),'raw_log_sha256':sha256(row.log),'audit':actual}


def predecessor_result(q,row,work_root,identity):
    ensure(q,row.stdout.splitlines().count('PROD_SEAM_P34_GATE=PASS')==1,'FRESH_P34_GATE_MARKER')
    work=Path(one_value(q,row.stdout,'VALIDATION_WORK='))
    path=Path(one_value(q,row.stdout,'PROD_SEAM_P34_RECEIPT='))
    ensure(q,path==work/'p34-receipt.json' and work!=q.work,'FRESH_P34_RECEIPT_PATH')
    receipt,children=audit34.actual_gate(work,sha256(path),q.before,
        {'new_source_sha256':p34.own_sources(),'isolated_identity':identity},work_root)
    return {'mode':'fresh-unchanged-canonical-runner','work':str(work),'receipt':str(path),
        'receipt_sha256':sha256(path),'raw_log':str(row.log),'raw_log_sha256':sha256(row.log),
        'strict':receipt['completed_stages']['strict'],'p33_predecessor':receipt['completed_stages']['p33_predecessor'],
        'child_work':[str(p) for p in children]}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--work-root',type=Path,required=True)
    args=parser.parse_args();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    if sys.flags.optimize or os.environ.get('PYTHONOPTIMIZE'):raise SystemExit('PYTHON_OPTIMIZATION_FORBIDDEN')
    if shutil.disk_usage(args.work_root).free<3*1024**3:raise SystemExit('P35_BUILD_ROOT_FREE_3GIB')
    q=Qualification(ROOT.parent,label='p35_gate',work_root=args.work_root)
    try:
        with q:
            p33,p32,p31,frozen=frozen_guard(q);own=own_sources()
            ensure(q,len(own)==14,'EXACT_FOURTEEN_P35_SUCCESSORS')
            q._json('p35-source-identities-before.json',own);q.bootstrap()
            identity=p34.git_guard(q,'pre');matrix=[];behavior={}
            for variant in range(3):
                name='lint_'+str(variant)
                row=q.verilator([*STRICT_FLAGS,'--lint-only','--top-module',TOP,'--Mdir',q.work/name,
                    *lint_parameters(variant),*rtl_sources(),*(ROOT/'rtl/memory'/(n+'.sv') for n in NEW_RTL)],name)
                matrix.append({'variant':variant,'parameters':lint_parameters(variant),'raw_log':str(row.log),'raw_log_sha256':sha256(row.log)})
            for phase,top in PHASES.items():
                behavior[phase]={}
                for variant in range(3):
                    name=phase+'_'+str(variant)
                    binary=q.build_simulation(top+'_tb',selected_sources(phase),name=name,parameters=[f'-GVARIANT={variant}'])
                    logs=list(q.work.glob('*_'+name+'_make.log'))
                    ensure(q,len(logs)==1 and not re.search(r'(?im)%Warning|%Error|\bwarning:|\berror:',logs[0].read_text()),'CXX_DIAGNOSTICS:'+name)
                    row=q.run([binary],name+'_sim',cwd=q.work,timeout=180,reject_diagnostics=True)
                    try:counts=parse_behavior(row.stdout,phase,variant)
                    except ValueError as error:q.fail('P35_BEHAVIOR',str(error))
                    behavior[phase][str(variant)]={'raw_log':str(row.log),'raw_log_sha256':sha256(row.log),'counts':counts}
                    print(row.stdout,end='',flush=True)
            row=q.run(['/usr/bin/python3','-B','-u',ROOT/'tests/run_p35_dedup_mutation.py','--work-root',args.work_root],
                'dedup_mutation',timeout=1800,reject_diagnostics=True)
            negative=mutation_result(q,row,args.work_root)
            row=q.run(['/usr/bin/python3','-B','-u',ROOT/'tests/run_prod_seam_p34.py','--work-root',args.work_root],
                'p34_canonical',timeout=6000,reject_diagnostics=True)
            predecessor=predecessor_result(q,row,args.work_root,identity)
            ensure(q,negative['work'] not in [predecessor['work'],*predecessor['child_work'],str(q.work)],'INDEPENDENT_NEGATIVE_STRICT_DOMAIN')
            frozen_guard(q);ensure(q,own_sources()==own,'P35_OWN_SOURCE_CONTAINMENT')
            post=p34.git_guard(q,'post');ensure(q,post==identity,'P35_GIT_PRE_POST')
            strict=q.assert_strict(minimum_elaborations=15);ensure(q,strict==STRICT,'P35_EXACT_STRICT_ACCOUNTING')
            commands=p31.command_records(q,q.work,expected_count=54);exact_commands(q,commands,q.work,args.work_root)
            completed={'matrix':matrix,'behavior':behavior,'mutation':negative,'p34_predecessor':predecessor,
                'p35_source_sha256':own,'frozen_p34_source_sha256':p34.own_sources(),'frozen_predecessor_sha256':frozen,
                'pre_identity':identity,'post_identity':post,'strict':strict,'commands':commands,
                'work_root':str(args.work_root),'exact_version':EXACT_VERSION,
                'live_containment_policy':read_json(ROOT.parent/audit34.P34_RECEIPT)['completed_stages']['live_containment_policy'],
                'live_containment_execution':'EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED'}
            q._json('p35-completed-stages.json',completed)
        summary=read_json(q.work/'summary.json');containment=read_json(q.work/'containment.json')
        ensure(q,summary['first_failure'] is None and summary['secondary_errors']==[] and summary['strict_verified'] is True
            and containment==CLEAN and own_sources()==own,'P35_FINAL_CONTAINMENT')
        receipt=q._json('p35-receipt.json',{'gate':'PROD_SEAM_P35_GATE=PASS','completed_stages':completed,
            'summary':summary,'containment':containment})
        print('PROD_SEAM_P35_EXACT_VERILATOR_5_050=PASS')
        print('PROD_SEAM_P35_BEHAVIOR=PASS simulations=12 scenarios=123')
        print('PROD_SEAM_P35_DEDUP_MUTATION=DETECTED')
        print('PROD_SEAM_P35_P34_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner')
        print('PROD_SEAM_P35_OUTER_STRICT_LEAK=0\nPROD_SEAM_P35_INNER_STRICT_LEAK=0')
        print('PROD_SEAM_P35_POST_CONTAINMENT=PASS\nPROD_SEAM_P35_RAW_INDEX_IDENTICAL=PASS')
        print('PROD_SEAM_P35_RECEIPT='+str(receipt))
        print('PROD_SEAM_P35_GATE=PASS')
        return 0
    except BaseException as error:
        failure=q._first_failure or {'stage':'P35_GATE_AUDIT','detail':repr(error),'rc':1}
        print('PROD_SEAM_P35_FIRST_FAILURE='+json.dumps(failure,sort_keys=True),flush=True)
        return 1


if __name__=='__main__':raise SystemExit(main())
