#!/usr/bin/env python3
"""Build mixed P44/P106 host workload; audit capture against external goldens.

  python3 tools/a0_p107_session.py build --plan PLAN.json --wire OUT.bin --manifest OUT.json
  python3 tools/a0_p107_session.py audit --plan PLAN.json --sent-wire COMMANDS.bin --capture HOST.bin

The tool does not upload commands to hardware or derive expected frame CRCs.
"""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'sim'))
from a0_p107_host_batch import compile_plan, audit_capture


def run(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='action', required=True)
    build = sub.add_parser('build')
    build.add_argument('--plan',type=Path,required=True)
    build.add_argument('--wire',type=Path,required=True)
    build.add_argument('--manifest',type=Path,required=True)
    audit = sub.add_parser('audit')
    audit.add_argument('--plan',type=Path,required=True)
    audit.add_argument('--capture',type=Path,required=True)
    audit.add_argument('--sent-wire',type=Path,required=True)
    args = ap.parse_args(argv)
    try:
        session = compile_plan(json.loads(args.plan.read_text(encoding='utf-8')))
        if args.action == 'build':
            if args.wire.resolve() == args.manifest.resolve():
                raise ValueError('wire and manifest outputs cannot have the same path')
            args.wire.write_bytes(session.wire)
            args.manifest.write_text(json.dumps(session.manifest(),indent=2,sort_keys=True)+'\n',encoding='utf-8')
            payload = {'status':'PASS','command_bytes':len(session.wire),**session.manifest()}
        else:
            payload = audit_capture(session,args.capture.read_bytes(),
                                    sent_wire=args.sent_wire.read_bytes())
    except (ValueError,TypeError,OSError,KeyError) as exc:
        print(json.dumps({'status':'FAIL','reason':str(exc)},sort_keys=True))
        return 1
    print(json.dumps(payload,sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(run())
