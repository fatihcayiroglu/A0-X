#!/usr/bin/env python3
"""Offline P120 planned telemetry audit. No device access or authenticated proof."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_p107_host_batch import compile_plan
from a0_p120_planned_telemetry import audit_planned_stream


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan', required=True, type=Path)
    p.add_argument('--capture', required=True, type=Path)
    p.add_argument('--sent-wire', required=True, type=Path)
    p.add_argument('--epoch', required=True)
    p.add_argument('--final-dropped', required=True, type=int)
    p.add_argument('--output', required=True, type=Path)
    a=p.parse_args(argv)
    try:
        sources={s.resolve() for s in (a.plan,a.capture,a.sent_wire)}
        if a.output.resolve() in sources:
            raise ValueError('output may not overwrite any evidence input')
        session=compile_plan(json.loads(a.plan.read_text()))
        report=audit_planned_stream(session,a.capture.read_bytes(),epoch=a.epoch,
                                  sent_wire=a.sent_wire.read_bytes(),
                                  final_dropped=a.final_dropped)
        # Only write report after all checks; atomic replace prevents partial JSON.
        import os
        import tempfile
        a.output.parent.mkdir(parents=True,exist_ok=True)
        fd,tmp=tempfile.mkstemp(prefix='.p120-',suffix='.tmp',dir=a.output.parent)
        try:
            with os.fdopen(fd,'w') as f:
                json.dump(report,f,indent=2,sort_keys=True)
                f.write('\n')
            os.replace(tmp,a.output)
        finally:
            if os.path.exists(tmp):os.unlink(tmp)
        print(json.dumps({'status':report['status'],'unverified':report['unverified_frame_indices']}))
        return 0 if report['status']=='FULL_SOFTWARE_CONSISTENCY' else 3
    except (ValueError,OSError,KeyError,TypeError) as exc:
        print('P120 REJECTED:',exc,file=sys.stderr)
        return 1


if __name__=='__main__':raise SystemExit(main())
