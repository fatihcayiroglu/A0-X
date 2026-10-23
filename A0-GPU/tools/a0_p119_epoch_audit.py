#!/usr/bin/env python3
"""P119 fail-closed OFFLINE host-capture auditing; never claims real GPU proof."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_p119_epoch_reconcile import EpochReconciler


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--epoch', required=True)
    parser.add_argument('--final-attempted', type=int, required=True)
    parser.add_argument('--final-dropped', type=int, required=True)
    parser.add_argument('--expected-tags', help='comma-separated decimal host command tags, or empty for none')
    parser.add_argument('--report', type=Path, help='optional new JSON path (must not already exist)')
    args = parser.parse_args(argv)
    try:
        if args.report and (args.report.exists() or args.report.is_symlink()
                            or args.report.resolve() == args.capture.resolve()):
            raise ValueError('report path must be a new path distinct from capture')
        tags = None if args.expected_tags is None else (
            [] if not args.expected_tags else [int(x) for x in args.expected_tags.split(',')]
        )
        validator = EpochReconciler(args.epoch)
        with args.capture.open('rb') as handle:
            while True:
                chunk = handle.read(65536)
                if not chunk:
                    break
                validator.feed(chunk)
        report = validator.finalize(final_attempted=args.final_attempted,
                                    final_dropped=args.final_dropped,
                                    expected_result_tags=tags)
        payload = json.dumps(report, indent=2, sort_keys=True) + '\n'
        if args.report:
            with args.report.open('x', encoding='utf8') as dst:
                dst.write(payload)
        print(payload, end='')
        return 0
    except (OSError, ValueError, TypeError) as exc:
        print(f'P119_EPOCH_AUDIT_FAIL: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
