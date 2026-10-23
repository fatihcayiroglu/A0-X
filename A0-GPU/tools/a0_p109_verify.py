#!/usr/bin/env python3
"""Independent P109 OFFLINE evidence consistency CLI, NOT hardware validation.

verify --plan plan.json --receipt receipt.json --capture capture.bin
       --sent-wire commands.bin [--report report.json]

batch --manifest manifest.json [--report report.json]
manifest: {"schema":"A0-P109-BATCH-v1", "sessions":[
  {"plan":"plan.json","receipt":"receipt.json","capture":"capture.bin",
   "sent_wire":"commands.bin"}, ...]}
All manifest paths are relative to the manifest file's directory. Batch epoch
labels must be unique. Never treat local labels as physical reset evidence.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_p107_host_batch import compile_plan
from a0_p109_capture_binding import verify_capture_binding, verify_epoch_batch


def _load(p: dict[str, Path]):
    session=compile_plan(json.loads(p['plan'].read_text(encoding='utf-8')))
    receipt=json.loads(p['receipt'].read_text(encoding='utf-8'))
    capture=p['capture'].read_bytes()
    wire=p['sent_wire'].read_bytes()
    return session, receipt, capture, wire


def _batch(p: Path):
    obj=json.loads(p.read_text(encoding='utf-8'))
    if type(obj) is not dict or set(obj) != {'schema','sessions'} or obj['schema'] != 'A0-P109-BATCH-v1':
        raise ValueError('invalid batch manifest')
    sessions=obj['sessions']
    if type(sessions) is not list or not 1 <= len(sessions) <= 128:
        raise ValueError('invalid number of batch entries')
    root=p.resolve().parent
    parsed=[]
    inputs=[p.resolve()]
    for i,entry in enumerate(sessions):
        if type(entry) is not dict or set(entry) != {'plan','receipt','capture','sent_wire'}:
            raise ValueError(f'invalid manifest entry {i}')
        paths={}
        for key,value in entry.items():
            if type(value) is not str or not value or Path(value).is_absolute():
                raise ValueError('manifest requires nonempty relative paths')
            path=(root/value).resolve()
            if not path.is_relative_to(root):
                raise ValueError('manifest input escapes containing directory')
            paths[key]=path
            inputs.append(path)
        parsed.append(_load(paths))
    return verify_epoch_batch(parsed),inputs


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    one=sub.add_parser('verify',help='cross-check four independent inputs')
    for name in ('plan','receipt','capture','sent-wire'):
        one.add_argument('--'+name,required=True,type=Path)
    one.add_argument('--report',type=Path)
    batch=sub.add_parser('batch',help='check bounded session manifest')
    batch.add_argument('--manifest',required=True,type=Path)
    batch.add_argument('--report',type=Path)
    a=parser.parse_args(argv)
    try:
        if a.action=='verify':
            inputs=[a.plan.resolve(),a.receipt.resolve(),a.capture.resolve(),a.sent_wire.resolve()]
            result=verify_capture_binding(*_load({'plan':a.plan,'receipt':a.receipt,
                                                   'capture':a.capture,'sent_wire':a.sent_wire}))
        else:
            result,inputs=_batch(a.manifest)
        if a.report is not None:
            target=a.report.resolve()
            if target in inputs:
                raise ValueError('report must not overwrite any input artifact')
            # Create exclusive output; no silently overwriting previous evidence.
            with a.report.open('x',encoding='utf-8') as stream:
                json.dump(result,stream,indent=2,sort_keys=True)
                stream.write('\n')
        print(json.dumps(result,sort_keys=True))
        return 0
    except (ValueError,TypeError,KeyError,OSError,UnicodeError,json.JSONDecodeError) as exc:
        print(json.dumps({'status':'FAIL','reason':str(exc)},sort_keys=True))
        return 1


if __name__=='__main__':
    raise SystemExit(main())
