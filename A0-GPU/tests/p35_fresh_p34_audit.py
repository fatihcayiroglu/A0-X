#!/usr/bin/python3
"""P35-owned portable audit of a fresh unchanged P34 predecessor domain.
Derived from the verified P34 read-only audit; only root/work-root plumbing and
local read-only helpers differ. Frozen P34 source is never edited or replaced.
"""
import sys
sys.dont_write_bytecode = True
import re
from pathlib import Path
from types import SimpleNamespace
import importlib.util
import hashlib
import json
import os
import subprocess
from p34_validation_support import Qualification, snapshot_tree, sha256

ROOT=Path(__file__).resolve().parents[2]
REPO=ROOT/'A0-GPU'
P34_RECEIPT='EVIDENCE/P34/CANONICAL/p34-receipt.json'
P34_RECEIPT_SHA='a88bb494f8fa5183dfb11a36636e2a79899fa816c61829bf0806e880459faaae'
CLEAN_CONTAINMENT={'added':[],'changed':[],'removed':[],'unchanged':True,'raw_index_identical':True}

def need(condition, detail):
    if not condition: raise RuntimeError(detail)

def read_json(path):
    return json.loads(Path(path).read_text())

def import_inert(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    need(spec is not None and spec.loader is not None,'IMPORT_SPEC')
    module=importlib.util.module_from_spec(spec)
    sys.modules[name]=module
    spec.loader.exec_module(module)
    return module

def git_identity(repo):
    def git(*args):
        env=os.environ.copy();env['GIT_OPTIONAL_LOCKS']='0'
        row=subprocess.run(['/usr/bin/git','-c','diff.autoRefreshIndex=false','-C',str(repo),*args],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=30)
        need(row.returncode==0 and not row.stderr,'READ_ONLY_GIT:'+repr(args))
        return row.stdout
    result={'head':git('rev-parse','HEAD').decode().strip(),
        'branch':git('branch','--show-current').decode().strip(),
        'tracked_diff_sha256':hashlib.sha256(git('diff','--binary')).hexdigest(),
        'index_semantic_sha256':hashlib.sha256(git('ls-files','--stage','-z')).hexdigest(),
        'raw_index_sha256':sha256(repo/'.git/index'),
        'staged_changes':git('diff','--cached','--name-status').decode()}
    return result,sorted(git('ls-files','--others','--exclude-standard').decode().splitlines())

STRICT = {'outer_calls': 19, 'inner_calls': 76, 'outer_elaborations': 18,
          'inner_elaborations': 18, 'outer_stripped_count': 0, 'inner_stripped_count': 0}


class ReadOnlyAudit:
    _strict_rows = Qualification._strict_rows
    def __init__(self, work, before):
        self.work, self.before, self.checkpoint = work, before, ROOT
        self.index_before = (REPO / '.git/index').read_bytes()
    def fail(self, stage, detail, rc=1):
        raise RuntimeError(f'{stage}: {detail}: rc={rc}')


def owned_gate_work(path, work_root):
    path = Path(path)
    need(path.parent == Path(work_root) and path.name.startswith('a0_p30_p34_gate_')
         and path.is_dir() and not path.is_symlink() and path.resolve(strict=True) == path,
         'P34_EXPLICIT_OWNED_GATE_WORK:' + str(path))
    return path


def exact_commands(work, commands, runner, p33, sources):
    expected = []
    outer = str(work / 'strict-all-outer-verilator.py')
    expected.append(('version', [outer, '--version'], REPO))
    def git(phase):
        for suffix, args in (
            ('head', ['rev-parse', 'HEAD']), ('branch', ['branch', '--show-current']),
            ('diffcheck', ['diff', '--check']), ('diff', ['diff', '--binary']),
            ('staged', ['diff', '--cached', '--name-status']),
            ('index_semantics', ['ls-files', '--stage', '-z'])):
            expected.append((phase+'_git_'+suffix, ['/usr/bin/git','-c','diff.autoRefreshIndex=false',*args], REPO))
    def sim(name, top, params, selected):
        obj = work / (name+'_obj')
        expected.append((name+'_generate', [outer,*runner.STRICT_FLAGS,'--cc','--exe','--main',
            '--top-module',top,'--Mdir',str(obj),*params,*(str(p) for p in selected),
            str(REPO/'tests/rtl'/(top+'.sv'))],REPO))
        expected.append((name+'_make',['/usr/bin/make','-C',str(obj),'-f','V'+top+'.mk','-j1'],REPO))
        expected.append((name+'_sim',[str(obj/('V'+top))],work))
    git('pre')
    for index,(name,values) in enumerate(p33.MATRIX):
        params=[f'-G{k}={v}' for k,v in zip(p33.PARAMETER_NAMES,values,strict=True)]
        params.append(f'-GCOHERENCE_GEN_W={index+1}')
        expected.append(('lint_'+name,[outer,*runner.STRICT_FLAGS,'--lint-only','--top-module',runner.TOP,
            '--Mdir',str(work/('lint_'+name)),*params,*(str(p) for p in sources)],REPO))
    for name,words,sets,gen in runner.COMPONENT_MATRIX:
        sim('component_'+name,runner.COMPONENT_TOP+'_tb',
            [f'-GLINE_WORDS={words}',f'-GSET_COUNT={sets}',f'-GGEN_W={gen}'],
            [REPO/'rtl/memory'/(runner.COMPONENT_TOP+'.sv')])
    for variant in range(3):
        sim('integrated_'+str(variant),runner.TB,[f'-GVARIANT={variant}'],sources)
    for name,params,mode,markers in p33.CASES:
        sim('predecessor_'+name,'a0_p34_predecessor_store_tb',params,sources)
    for name,top,params in (
        ('memory','a0_p34_predecessor_memory_tb',()),
        ('memorywrap','a0_p34_predecessor_memory_tb',('-GMODE=1','-GGEN=1')),
        ('order','a0_p34_predecessor_order_tb',()),('guard','a0_p34_predecessor_guard_tb',())):
        sim('predecessor_'+name,top,params,[REPO/'rtl/memory/a0_store_read_coherence_order_guard.sv'] if name=='guard' else sources)
    expected.append(('p33_canonical',['/usr/bin/python3','-u',str(REPO/'tests/run_prod_seam_p33.py')],REPO))
    git('post')
    need(len(expected)==62 and set(commands)=={f'{i:03d}_{name}.log' for i,(name,_,_) in enumerate(expected,1)},
         'P34_EXACT_COMMAND_SEQUENCE')
    for index,(name,argv,cwd) in enumerate(expected,1):
        row=commands[f'{index:03d}_{name}.log']; meta=read_json(row['metadata'])
        need(row['command']==argv and meta['command']==argv and meta['cwd']==str(cwd),'P34_EXACT_COMMAND:'+name)
        if name.endswith('_make'):
            need(not re.search(r'(?im)%Warning|%Error|\bwarning:|\berror:',(work/f'{index:03d}_{name}.log').read_text()),
                 'P34_CXX_DIAGNOSTICS:'+name)


def actual_gate(work, receipt_sha, before, promotion, work_root):
    work=owned_gate_work(work, work_root)
    need(sha256(ROOT/P34_RECEIPT)==P34_RECEIPT_SHA,'FROZEN_P34_RECEIPT')
    frozen_receipt=read_json(ROOT/P34_RECEIPT)
    policy=frozen_receipt['completed_stages']['live_containment_policy']
    need(snapshot_tree(ROOT)==before,'P34_CURRENT_TREE_PREAUDIT')
    need(sha256(work/'p34-receipt.json')==receipt_sha,'P34_PINNED_CANONICAL_RECEIPT')
    receipt=read_json(work/'p34-receipt.json'); completed=read_json(work/'p34-completed-stages.json')
    summary=read_json(work/'summary.json'); containment=read_json(work/'containment.json')
    need(receipt=={'gate':'PROD_SEAM_P34_GATE=PASS','completed_stages':completed,'summary':summary,'containment':containment},
         'P34_RECEIPT_BINDING')
    need(summary['first_failure'] is None and summary['secondary_errors']==[] and summary['strict_verified'] is True
         and summary['checkpoint']==str(ROOT) and summary['work']==str(work) and containment==CLEAN_CONTAINMENT,
         'P34_CANONICAL_CONTAINMENT')
    need(before==read_json(work/'checkpoint-before.json')==read_json(work/'checkpoint-after.json')
         and (work/'index-before.raw').read_bytes()==(REPO/'.git/index').read_bytes(),'P34_FULL_TREE_RAW_INDEX')
    sys.path.insert(0,str(REPO/'tests'))
    runner=import_inert('p34_qualified_readonly_runner',REPO/'tests/run_prod_seam_p34.py')
    q=ReadOnlyAudit(work,before)
    p33,p32,p31,frozen=runner.frozen_guard(q)
    own=runner.own_sources()
    need(len(own)==17 and own==completed['p34_source_sha256']==promotion['new_source_sha256']
         ==frozen_receipt['completed_stages']['p34_source_sha256'],'P34_PROMOTED_SOURCE_SET')
    need(completed['frozen_p33_source_sha256']==runner.P33_OWN and completed['frozen_predecessor_sha256']==frozen,
         'P34_FROZEN_SOURCE_SET')
    need(completed['live_containment_policy']==policy
         and completed['live_containment_execution']=='EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED','P34_LIVE_POLICY')
    identity=completed['pre_identity']
    need(identity==completed['post_identity']==git_identity(REPO)[0]==promotion['isolated_identity'], 'P34_EXACT_GIT_IDENTITY')
    need(read_json(work/'pre-git-identity.json')==identity==read_json(work/'post-git-identity.json'),'P34_RAW_GIT_RECEIPTS')
    commands=p31.command_records(q,work,expected_count=62)
    need(commands==completed['commands'],'P34_COMMAND_REAUDIT')
    sources=[REPO/'rtl/memory'/n for n in (*runner.FROZEN_RTL,*runner.NEW_RTL)]
    need(len(sources)==completed['rtl_source_count']==18,'P34_RTL_SOURCE_COUNT')
    exact_commands(work,commands,runner,p33,sources)
    outer=q._strict_rows(work/'strict-outer.jsonl',outer=True); inner=q._strict_rows(work/'strict-inner.jsonl',outer=False)
    elab=lambda rows:sum('--lint-only' in r['forwarded'] or '--cc' in r['forwarded'] for r in rows)
    actual={'outer_calls':len(outer),'inner_calls':len(inner),'outer_elaborations':elab(outer),
        'inner_elaborations':elab(inner),'outer_stripped_count':0,'inner_stripped_count':0}
    need(actual==STRICT==completed['strict'],'P34_STRICT_ACCOUNTING')
    need((work/'001_version.log').read_text().strip()==runner.EXACT_VERSION,'P34_EXACT_VERSION')
    provenance=read_json(work/'toolchain-provenance.json')
    need(provenance['archive_sha256']=='55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451','P34_TOOLCHAIN_ARCHIVE')
    for name,expected in provenance['identities'].items():
        p=Path(name)
        need(work in p.parents and not p.is_symlink() and sha256(p)==expected,'P34_PHYSICAL_TOOLCHAIN:'+name)
    def raw(row,stage):
        log=Path(row['raw_log'])
        need(log.parent==work and log.name in commands and log.name.endswith('_'+stage+'.log')
             and row['raw_log_sha256']==sha256(log),'P34_RAW_REFERENCE:'+str(log))
        return SimpleNamespace(log=log,stdout=log.read_text(),rc=0)
    need(len(completed['matrix'])==3 and len(completed['components'])==3
         and set(completed['integrated'])=={'0','1','2'} and len(completed['behavior'])==9,'P34_COVERAGE_CARDINALITY')
    for index,(row,(name,values)) in enumerate(zip(completed['matrix'],p33.MATRIX,strict=True)):
        params=[f'-G{k}={v}' for k,v in zip(p33.PARAMETER_NAMES,values,strict=True)]+[f'-GCOHERENCE_GEN_W={index+1}']
        need(row['variant']==name and row['parameters']==params,'P34_MATRIX_PARAMETERS'); raw(row,'lint_'+name)
    for name,words,sets,gen in runner.COMPONENT_MATRIX:
        row=completed['components'][name]
        need(row['summary']==runner.behavior_summary(q,raw(row,'component_'+name+'_sim'),words,sets,gen),'P34_COMPONENT_RAW_COUNTS')
    for variant in range(3):
        row=completed['integrated'][str(variant)]
        need(row['summary']==runner.direct_behavior(q,raw(row,'integrated_'+str(variant)+'_sim'),variant),'P34_INTEGRATED_RAW_COUNTS')
    for name,params,mode,markers in p33.CASES:
        row=completed['behavior'][name]
        need(row==runner.regression(q,raw(row,'predecessor_'+name+'_sim'),p33,markers,params,mode=mode),'P34_STORE_RAW_COUNTS')
    for name,params,markers,summarizer in (
        ('memory',(),p33.MEMORY_MARKERS,None),('memorywrap',('-GMODE=1','-GGEN=1'),p33.MEMORY_WRAP_MARKERS,p33.memory_wrap_summary),
        ('order',(),p33.ORDER_MARKERS,p33.order_summary),('guard',(),p33.GUARD_MARKERS,p33.guard_summary)):
        row=completed['behavior'][name]
        need(row==runner.regression(q,raw(row,'predecessor_'+name+'_sim'),p33,markers,params,summarizer=summarizer),'P34_ADAPTED_RAW_COUNTS')
    child=completed['p33_predecessor']
    audited=runner.audit_fresh_p33(q,raw(child,'p33_canonical'),p33,p32,p31,frozen,identity)
    need(child==audited,'P34_P33_RECURSIVE_RAW_AUDIT'); runner.audit_toolchain_domains(q,audited)
    c32=child['p32_predecessor']; c31=c32['p31_predecessor']; c30=c31['p30_predecessor']
    children=[Path(c['work']) for c in (child,c32,c31,c30)]
    need(len(set([work,*children]))==5,'P34_FIVE_INDEPENDENT_DOMAINS')
    need(snapshot_tree(ROOT)==before and sha256(work/'p34-receipt.json')==receipt_sha,'P34_POST_RAW_AUDIT_IDENTITY')
    return receipt,children
