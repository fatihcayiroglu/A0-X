#!/usr/bin/env python3
"""OFFLINE P108 host writer fault-injection tool. NO PHYSICAL DEVICE I/O.

python3 tools/a0_p108_transfer.py simulate --plan PLAN.json \
  --events SIMULATED.json --receipt RECEIPT.json [--capture CAPTURE.bin]

Each event is {"tick": 1, "accept": 8} or {"tick": 2, "fault": "io_error"}.
The events are scripted *simulated* writer results, not authentic device logs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_p107_host_batch import compile_plan
from a0_p108_transfer_guard import (TransferGuard, SENDING, HOST_ACCEPTED_UNVERIFIED,
                                    CAPTURE_AUDITED, verify_receipt)


def simulate(plan, events, *, epoch, chunk, timeout, capture=None):
    session = compile_plan(plan)
    guard = TransferGuard(session, epoch=epoch, reset_acknowledged=True,
                          max_chunk=chunk, timeout_ticks=timeout)
    if type(events) is not list or not events or len(events) > 100000:
        raise ValueError('expected nonempty bounded simulated events list')
    for event in events:
        if type(event) is not dict or 'tick' not in event:
            raise ValueError('event must contain tick')
        if set(event) not in ({'tick','accept'}, {'tick','fault'}):
            raise ValueError('event must have exactly tick/accept or tick/fault')
        if guard.status != SENDING:
            raise ValueError('events continue after terminal transport state')
        if 'fault' in event:
            if event['fault'] != 'io_error':
                raise ValueError('unrecognized writer fault')
            def writer(data):
                raise OSError('simulated write may have unreported side effects')
        else:
            n = event['accept']
            def writer(data):
                return n
        guard.poll(event['tick'], writer)
    receipt = guard.receipt()
    receipt['evidence_kind'] = 'OFFLINE_SCRIPTED_SIMULATION_NOT_HOST_CAPTURE'
    if capture is not None:
        try:
            result=guard.audit(capture)
            receipt.update(guard.receipt())
            receipt['capture_audit'] = result
        except (RuntimeError, ValueError, TypeError) as exc:
            receipt['capture_audit'] = {'status':'FAIL','reason':str(exc)}
    success = guard.status in (HOST_ACCEPTED_UNVERIFIED, CAPTURE_AUDITED)
    if capture is not None:
        success = success and receipt['capture_audit']['status'] == 'PASS'
    return success, receipt


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    p=sub.add_parser('simulate',help='scripted software fault injection, not physical TX')
    p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--events',type=Path,required=True)
    p.add_argument('--receipt',type=Path,required=True)
    p.add_argument('--capture',type=Path)
    p.add_argument('--epoch',type=str,default='simulated-reset-1')
    p.add_argument('--chunk',type=int,default=16)
    p.add_argument('--timeout',type=int,default=5)
    verify=sub.add_parser('verify',help='receipt self-consistency only; not device evidence')
    verify.add_argument('--plan',type=Path,required=True)
    verify.add_argument('--receipt',type=Path,required=True)
    args=parser.parse_args(argv)
    try:
        if args.action == 'verify':
            session=compile_plan(json.loads(args.plan.read_text(encoding='utf-8')))
            receipt=json.loads(args.receipt.read_text(encoding='utf-8'))
            result=verify_receipt(session,receipt)
            print(json.dumps(result,sort_keys=True))
            return 0
        source=[args.plan,args.events]+([args.capture] if args.capture is not None else [])
        if args.receipt.resolve() in {x.resolve() for x in source}:
            raise ValueError('receipt must not overwrite input artifacts')
        events=json.loads(args.events.read_text(encoding='utf-8'))
        plan=json.loads(args.plan.read_text(encoding='utf-8'))
        capture=args.capture.read_bytes() if args.capture else None
        success,receipt=simulate(plan,events,epoch=args.epoch,
                                 chunk=args.chunk,timeout=args.timeout,capture=capture)
        args.receipt.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n',encoding='utf-8')
        print(json.dumps({'status':'PASS' if success else 'FAIL',
                          'transfer_state':receipt['state'],
                          'host_accepted_bytes':receipt['host_accepted_bytes'],
                          'device_io_performed':False},sort_keys=True))
        return 0 if success else 1
    except (ValueError,TypeError,OSError,KeyError) as exc:
        print(json.dumps({'status':'FAIL','reason':str(exc)},sort_keys=True))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
