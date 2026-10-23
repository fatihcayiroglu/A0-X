#!/usr/bin/python3
"""Expected-negative P35 commit-dedup witness in its own strict tool domain.

The bad fixture's qualification summary remains FAILED. Only the exact recorded
assertion after a clean build is classified as mutation detection. This script
does not emit a P35 canonical gate or CLOSED marker.
"""
import sys
sys.dont_write_bytecode=True
import argparse,json,re,resource
from pathlib import Path
from p34_validation_support import Qualification,ValidationFailure,STRICT_FLAGS,EXACT_VERSION,sha256

ROOT=Path(__file__).resolve().parents[1]
CTRL='a0_cache_backed_atomic_controller'
TOP=CTRL+'_tb'
NEEDLE='                        else if(entry_committed_q[match_entry]) begin'
INJECTION='''                        // NEGATIVE FIXTURE ONLY: deliberately reapply a committed ADD.
                        else if(entry_committed_q[match_entry] && req_op_i==4'd2) begin
                            active_entry_q<=ENTRY_INDEX_W'(match_entry);
                            entry_committed_q[match_entry]<=0;
                            state_q<=READ_REQ;
                        end
'''
CLEAN={'added':[],'changed':[],'removed':[],'unchanged':True,'raw_index_identical':True}


def need(ok,detail):
    if not ok:raise RuntimeError(detail)


def read_json(path):return json.loads(Path(path).read_text())


def sources():
    good=ROOT/'rtl/memory'/(CTRL+'.sv')
    bad=ROOT/'tests/fixtures/p35_no_commit_dedup'/(CTRL+'.sv')
    tb=ROOT/'tests/rtl'/(TOP+'.sv')
    need(good.read_text().count(NEEDLE)==1 and bad.read_text()==good.read_text().replace(NEEDLE,INJECTION+NEEDLE),
        'EXACT_SINGLE_COMMITTED_ADD_DEDUP_MUTATION')
    return good,bad,tb


class Reader:
    _strict_rows=Qualification._strict_rows
    def fail(self,stage,detail,rc=1):raise RuntimeError(stage+':'+detail)


def audit_mutation(work,before,index_before,pins):
    work=Path(work);good,bad,tb=sources()
    need(not work.is_symlink() and work.resolve(strict=True)==work and work.name.startswith('a0_p30_p35_expected_mutation_'),
        'EXACT_NEGATIVE_WORK')
    for name,expected in pins.items():need(sha256(Path(name))==expected,'MUTATION_SOURCE_IDENTITY:'+name)
    need(read_json(work/'checkpoint-before.json')==before==read_json(work/'checkpoint-after.json')
        and (work/'index-before.raw').read_bytes()==index_before==(ROOT/'.git/index').read_bytes(),
        'NEGATIVE_FULL_SOURCE_RAW_INDEX')
    summary=read_json(work/'summary.json');failure=summary['first_failure']
    need(failure is not None and failure['stage']=='mutant_sim' and failure['rc'] in (1,-6)
        and summary['secondary_errors']==[] and summary['strict_verified'] is True
        and summary['checkpoint']==str(ROOT.parent) and summary['work']==str(work)
        and read_json(work/'containment.json')==CLEAN,'EXPECTED_NEGATIVE_WITH_CLEAN_CONTAINMENT')
    outer=work/'strict-all-outer-verilator.py';obj=work/'mutant_obj'
    commands=[('version',[str(outer),'--version'],ROOT,30),
        ('mutant_generate',[str(outer),*STRICT_FLAGS,'--cc','--exe','--main','--top-module',TOP,
            '--Mdir',str(obj),'-GVARIANT=2',str(bad),str(tb)],ROOT,600),
        ('mutant_make',['/usr/bin/make','-C',str(obj),'-f','V'+TOP+'.mk','-j1'],ROOT,600),
        ('mutant_sim',[str(obj/('V'+TOP))],work,180)]
    metadata_paths=[p for p in sorted(work.glob('[0-9][0-9][0-9]_*.json')) if 'command' in read_json(p)]
    need([p.name for p in metadata_paths]==[f'{i:03d}_{row[0]}.json' for i,row in enumerate(commands,1)],'NEGATIVE_EXACT_COMMAND_SET')
    records=[]
    for number,(name,argv,cwd,timeout) in enumerate(commands,1):
        path=work/f'{number:03d}_{name}.json';meta=read_json(path);log=path.with_suffix('.log')
        need(meta['command']==argv and meta['cwd']==str(cwd) and meta['timeout_seconds']==timeout
            and meta['raw_log']==str(log) and meta['raw_log_sha256']==sha256(log)
            and not meta['timed_out'] and not meta['interrupted'] and meta['lifecycle']['group_gone']
            and not meta['lifecycle']['group_existed_after_wait'],'NEGATIVE_COMMAND_LIFECYCLE:'+name)
        need(meta['rc']==(failure['rc'] if name=='mutant_sim' else 0),'NEGATIVE_EXACT_RETURN_CODE:'+name)
        if name!='mutant_sim':need(not re.search(r'(?im)%Warning|%Error|\bwarning:|\berror:',log.read_text()),'NEGATIVE_COMPILE_DIAGNOSTIC')
        records.append({'metadata':str(path),'sha256':sha256(path),'raw_log_sha256':sha256(log)})
    raw=work/'004_mutant_sim.log';text=raw.read_text()
    markers=[line for line in text.splitlines() if line.startswith('P35_')]
    need(markers==['P35_COMPONENT_SCENARIO_PASS id=1 name=RESET_AND_CERTIFICATE',
        'P35_COMPONENT_SCENARIO_PASS id=2 name=PENDING_REPLAY_RETURN_AND_RESULT_BACKPRESSURE']
        and re.findall(r'P35_COMPONENT_CHECK_FAILED cycle=(\d+) return effect or untouched bytes differ',text)==['30']
        and 'P35_COMPONENT_PASS' not in text,'EXACT_NONIDEMPOTENT_REPLAY_WITNESS')
    reader=Reader();outer_rows=reader._strict_rows(work/'strict-outer.jsonl',outer=True)
    inner=reader._strict_rows(work/'strict-inner.jsonl',outer=False)
    need(len(outer_rows)==2 and len(inner)==8
        and sum('--cc' in r['forwarded'] for r in outer_rows)==1
        and sum('--cc' in r['forwarded'] for r in inner)==1
        and [r['forwarded'] for r in outer_rows]==[commands[0][1][1:],commands[1][1][1:]],'NEGATIVE_EXACT_STRICT')
    need((work/'001_version.log').read_text().strip()==EXACT_VERSION,'NEGATIVE_EXACT_VERSION')
    provenance=read_json(work/'toolchain-provenance.json')
    need(provenance['archive_sha256']=='55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451','NEGATIVE_TOOLCHAIN_ARCHIVE')
    for name,expected in provenance['identities'].items():
        path=Path(name);need(work in path.parents and not path.is_symlink() and sha256(path)==expected,'NEGATIVE_PHYSICAL_TOOLCHAIN')
    return {'classification':'P35_COMMITTED_ADD_DEDUP_MUTATION_DETECTED',
        'fixture_qualification_status':'FAILED_AS_EXPECTED_NOT_DUT_PASS','work':str(work),
        'first_failure':failure,'source_sha256':pins,'commands':records,'raw_log':str(raw),
        'raw_log_sha256':sha256(raw),'strict':{'outer_calls':2,'inner_calls':8,'elaborations':1,'suppression_leaks':'0/0'},
        'compile_diagnostics':'0/0','containment':CLEAN}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--work-root',type=Path,required=True)
    args=parser.parse_args();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    good,bad,tb=sources();pins={str(p):sha256(p) for p in (good,bad,tb,Path(__file__))}
    q=Qualification(ROOT.parent,label='p35_expected_mutation',work_root=args.work_root)
    caught=None
    try:
        with q:
            q._json('negative-fixture.json',{'source_sha256':pins,'intentional_mutation':'REAPPLY_COMMITTED_ADD',
                'expected_first_failure':'mutant_sim','real_dut_pass_claim':False})
            q.bootstrap()
            binary=q.build_simulation(TOP,[bad,tb],name='mutant',parameters=['-GVARIANT=2'])
            q.run([binary],'mutant_sim',cwd=q.work,timeout=180)
            q.fail('MUTATION_NOT_DETECTED','Bad ADD replay fixture survived')
    except ValidationFailure as error:caught=error
    need(caught is not None and caught.stage=='mutant_sim','NO_EXPECTED_REPLAY_FAILURE')
    result=audit_mutation(q.work,q.before,q.index_before,pins)
    receipt=q._json('mutation-detection-receipt.json',result)
    print('P35_EXPECTED_DEDUP_MUTATION=DETECTED',flush=True)
    print('P35_MUTATION_RECEIPT='+str(receipt),flush=True)
    print('P35_MUTATION_RECEIPT_SHA256='+sha256(receipt),flush=True)
    return 0


if __name__=='__main__':raise SystemExit(main())
