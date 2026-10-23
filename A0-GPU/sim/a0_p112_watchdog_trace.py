"""P112 deterministic pin-level oracle vectors for the unchanged P111 watchdog.

This generates input *and expected output* for a future RTL run; it does NOT
execute HDL. Expected signals come from the P111 clock-step reference model.
Use parse_and_replay() to reject truncated or forged vectors before HDL use.
"""
from __future__ import annotations

from collections import Counter
from hashlib import sha256
from pathlib import Path
import json
import random
import sys

from a0_p111_completion_watchdog import CompletionWatchdog

COLUMNS = (
    'rst_n', 'cmd_valid', 'cmd_ready', 'cmd_tag',
    'completion_valid', 'completion_ready', 'completion_tag', 'completion_error',
    'fault_sticky', 'pending', 'active_tag', 'last_fault_tag',
    'timeout_count', 'tag_mismatch_count', 'protocol_fault_count', 'completed_count',
)
WIDTHS = (1,1,1,16,1,1,16,1,1,1,16,16,32,32,32,32)
MAX_WAIT=7
CYCLES=4096
SEED=112


def expected(model: CompletionWatchdog) -> tuple[int,...]:
    s=model.snapshot()
    return (int(s.state=='FAULT'),int(s.state in ('WAIT','HOLD')),
            s.active_tag,s.last_fault_tag,s.timeouts,s.tag_mismatches,
            s.protocol_faults,s.completed)


def generate_rows(*, cycles: int=CYCLES, seed: int=SEED) -> list[tuple[int,...]]:
    if type(cycles) is not int or cycles < 100 or cycles > 100000:
        raise ValueError('cycles must be 100..100000')
    if type(seed) is not int:
        raise ValueError('seed must be integer')
    rng=random.Random(seed)
    m=CompletionWatchdog(max_wait=MAX_WAIT)
    rows=[]
    def emit(rst=1,cv=0,cr=0,ct=0,rv=0,rr=0,rt=0,re=0):
        if not rst:
            m.reset()
        else:
            m.tick(accepting=bool(cv and cr), accepted_tag=ct,
                   response_valid=bool(rv),response_tag=rt,
                   response_ready=bool(rr),response_error=bool(re))
        rows.append((rst,cv,cr,ct,rv,rr,rt,re)+expected(m))
    def reset():
        emit(0); emit(0);emit(1)
    # Guided cases cover boundaries and every fault class before fuzzing.
    reset(); emit(cv=1,cr=1,ct=0xabcd);emit(rv=1,rr=1,rt=0xabcd)
    reset(); emit(cv=1,cr=1,ct=23);emit();emit(rv=1,rt=23,re=1)
    for _ in range(22):emit(rv=1,rt=23,re=1)
    emit(rv=1,rr=1,rt=23,re=1)
    reset(); emit(cv=1,cr=1,ct=10);emit(rv=1,rr=1,rt=11)
    reset(); emit(cv=1,cr=1,ct=7)
    for _ in range(MAX_WAIT):emit()
    reset();emit(rv=1,rr=1,rt=22)
    reset();emit(cv=1,cr=1,ct=4);emit(cv=1,cr=1,ct=5)
    reset();emit(cv=1,cr=1,ct=4);emit(rv=1,rt=4);emit()
    reset();emit(cv=1,cr=1,ct=4);emit(rv=1,rt=4);emit(rv=1,rt=5)
    reset();emit(cv=1,cr=1,ct=4);emit(rv=1,rt=4,re=1);emit(rv=1,rt=4,re=0)
    reset();emit(cv=1,cr=1,ct=4);emit(rv=1,rt=4);emit(cv=1,cr=1,ct=5,rv=1,rt=4)
    # Random traffic, including deliberate attempts to change stalled results,
    # command valid with !ready, orphan completions and terminal faults.
    while len(rows)<cycles:
        if len(rows)+4 >= cycles:emit();continue
        reset()
        episode=rng.randrange(10)
        tag=rng.randrange(65536)
        if episode==0:
            for _ in range(rng.randrange(1,8)):
                emit(cv=rng.randrange(2),cr=0,ct=rng.randrange(65536))
        elif episode==1:
            emit(cv=1,cr=1,ct=tag)
            for _ in range(rng.randrange(MAX_WAIT)):
                emit(cv=rng.randrange(2),cr=0,ct=rng.randrange(65536))
            err=rng.randrange(2)
            for _ in range(rng.randrange(0,15)):
                emit(rv=1,rt=tag,re=err)
            emit(rv=1,rr=1,rt=tag,re=err)
        elif episode==2:
            emit(cv=1,cr=1,ct=tag)
            for _ in range(MAX_WAIT):emit()
        elif episode==3:
            emit(rv=1,rr=rng.randrange(2),rt=tag)
        elif episode==4:
            emit(cv=1,cr=1,ct=tag)
            emit(rv=1,rr=1,rt=tag^1)
        elif episode==5:
            emit(cv=1,cr=1,ct=tag);emit(cv=1,cr=1,ct=tag^1)
        elif episode==6:
            emit(cv=1,cr=1,ct=tag);emit(rv=1,rt=tag)
            emit(rv=1,rt=tag^1)
        elif episode==7:
            emit(cv=1,cr=1,ct=tag);emit(rv=1,rt=tag,re=0)
            emit(rv=1,rt=tag,re=1)
        elif episode==8:
            emit(cv=1,cr=1,ct=tag);emit(rv=1,rt=tag)
            emit(rv=0,rt=tag)
        else:
            emit(cv=1,cr=1,ct=tag)
            for _ in range(rng.randrange(1,MAX_WAIT)):emit()
            emit(rv=1,rr=1,rt=tag)
        for _ in range(rng.randrange(0,4)):
            emit(cv=rng.randrange(2),cr=rng.randrange(2),ct=rng.randrange(65536),
                 rv=rng.randrange(2),rr=rng.randrange(2),rt=rng.randrange(65536),
                 re=rng.randrange(2))
    return rows[:cycles]


def serialize(rows: list[tuple[int,...]]) -> bytes:
    lines=[]
    for row in rows:
        if len(row)!=len(COLUMNS):raise ValueError('column count mismatch')
        for value,width in zip(row,WIDTHS):
            if type(value) is not int or value<0 or value>=1<<width:
                raise ValueError('out of range trace field')
        lines.append(' '.join(f'{v:x}' for v in row))
    return ('\n'.join(lines)+'\n').encode('ascii')


def parse_and_replay(blob: bytes, *, max_wait: int=MAX_WAIT) -> dict:
    try:
        lines=blob.decode('ascii').splitlines()
    except UnicodeError as exc:raise ValueError('non-ascii trace') from exc
    if not lines:raise ValueError('empty trace')
    m=CompletionWatchdog(max_wait=max_wait)
    counts=Counter(); prev_fault=False
    for ix,line in enumerate(lines):
        fields=line.split(' ')
        if len(fields)!=16 or any(not x or any(c not in '0123456789abcdef' for c in x) for x in fields):
            raise ValueError(f'line {ix+1}: noncanonical column encoding')
        row=tuple(int(x,16) for x in fields)
        if serialize([row]) != (line+'\n').encode('ascii'):
            raise ValueError(f'line {ix+1}: noncanonical hex')
        rst,cv,cr,ct,rv,rr,rt,re=row[:8]
        previous = m.snapshot()
        if rst==0:
            m.reset();counts['reset_cycles']+=1
        else:
            m.tick(accepting=bool(cv and cr),accepted_tag=ct,
                   response_valid=bool(rv),response_ready=bool(rr),
                   response_tag=rt,response_error=bool(re))
        exp=expected(m)
        if row[8:]!=exp:
            raise ValueError(f'line {ix+1}: expected RTL outputs disagree with oracle')
        counts['cycles']+=1
        if rst and cv and cr:counts['command_accepts']+=1
        if rst and rv and not rr:counts['stalled_response_cycles']+=1
        if exp[0] and not prev_fault:counts['fault_entries']+=1
        if not exp[0] and prev_fault:counts['fault_resets']+=1
        if exp[1]:counts['pending_cycles']+=1
        if rst and m.timeouts>previous.timeouts:counts['timeout_faults']+=1
        if rst and m.tag_mismatches>previous.tag_mismatches:counts['tag_mismatch_faults']+=1
        if rst and m.protocol_faults>previous.protocol_faults:counts['protocol_faults']+=1
        if rst and m.completed>previous.completed:counts['completed_transactions']+=1
        if rst and rv and rr and not exp[0]:counts['successful_response_cycles']+=1
        prev_fault=bool(exp[0])
    return dict(counts)


def materialize(vector_path:Path, metadata_path:Path, *, cycles:int=CYCLES)->dict:
    blob=serialize(generate_rows(cycles=cycles))
    stats=parse_and_replay(blob)
    digest=sha256(blob).hexdigest()
    meta={'format':'P112_P111_PIN_TRACE_V1', 'seed':SEED,'cycles':cycles,
          'max_wait_cycles':MAX_WAIT,'sha256':digest,'columns':list(COLUMNS),
          'coverage':stats,'evidence_class':'PYTHON_ORACLE_NOT_HDL_SIMULATION'}
    vector_path.parent.mkdir(parents=True,exist_ok=True)
    vector_path.write_bytes(blob)
    metadata_path.write_text(json.dumps(meta,indent=2,sort_keys=True)+'\n')
    return meta


if __name__=='__main__':
    p=Path(__file__).resolve().parents[1]/'tests'/'vectors'
    print(json.dumps(materialize(p/'p112_watchdog_4096.hex',p/'p112_watchdog_4096.json'),indent=2))
