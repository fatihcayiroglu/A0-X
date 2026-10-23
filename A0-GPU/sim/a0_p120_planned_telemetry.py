"""P120 plan-bound, incremental A0GR/A0GF/A0GL reconciliation.

Correlates P107 independently supplied expected CRCs and command tags with
P119 per-epoch accounting. A valid CRC32 authenticates no hardware or sender.
A lost frame is *not* proven rendered: partial reports are never FULL PASS.
"""
from __future__ import annotations

from hashlib import sha256
from a0_p107_host_batch import CompiledSession
from a0_p119_epoch_reconcile import EpochReconciler


class PlannedTelemetryAudit(EpochReconciler):
    """Stream packet data in bounded 64KiB slices; don't accumulate responses.

    Only per-plan <=4096 expected tags / <=128 expected image CRCs retained.
    A reset event is not inferred. The external caller must bound the epoch.
    """
    def __init__(self, session: CompiledSession, *, epoch: str, sent_wire: bytes):
        if not isinstance(session, CompiledSession):
            raise ValueError('P107 CompiledSession required')
        if type(sent_wire) is not bytes or sent_wire != session.wire:
            raise ValueError('independently supplied sent-wire does not match plan')
        if session.sha256 != sha256(session.wire).hexdigest():
            raise ValueError('compiled plan SHA256 inconsistent')
        if not 1 <= len(session.expected_crcs) <= 128 or not 1 <= session.command_count <= 4096:
            raise ValueError('plan command/frame bounds violated')
        super().__init__(epoch)
        self.session = session
        self._tags = tuple(d.command.tag for d in session.draws)
        self._goldens = session.expected_crcs
        self._verified_results = 0
        self._verified_indices: list[int] = []

    def _accept(self, row: dict) -> None:
        kind = row['kind']
        if kind == 'result':
            i = self._verified_results
            if i >= len(self._tags) or row['tag'] != self._tags[i] or row['error']:
                raise ValueError(f'host result tag/status mismatch at command {i}')
            self._verified_results += 1
            return
        if kind == 'frame':
            attempt = self.frame_count + row['dropped']
            if attempt >= len(self._goldens):
                raise ValueError('unplanned frame attempt')
            if row['error'] or row['frame_crc'] != self._goldens[attempt]:
                raise ValueError(f'frame {attempt} golden CRC/error mismatch')
            if row['good'] != attempt + 1 or row['bad'] or row['aborted']:
                raise ValueError(f'frame {attempt} progress/error counters inconsistent')
            # Append only after parent validates sequence and monotone counters.
            super()._accept(row)
            self._verified_indices.append(attempt)
        else:
            if kind == 'loss_notice' and (row['bad'] or row['aborted']):
                raise ValueError('loss notice reports bad/aborted frames')
            super()._accept(row)

    def finalize(self, *, final_dropped: int) -> dict:
        if self._closed or self._poisoned:
            raise ValueError('session is closed or invalidated')
        # Explicit terminal boundary must cover all *planned* attempts.
        if self._verified_results != len(self._tags):
            self._closed = True
            raise ValueError('missing planned command results')
        report = super().finalize(final_attempted=len(self._goldens),
                                  final_dropped=final_dropped)
        delivered = set(self._verified_indices)
        missing = [i for i in range(len(self._goldens)) if i not in delivered]
        if len(missing) != final_dropped:
            raise ValueError('missing golden frame index accounting')
        full = not missing
        report.update({
            'schema': 'A0-P120-PLAN-BOUND-TELEMETRY-v1',
            'status': 'FULL_SOFTWARE_CONSISTENCY' if full else 'PARTIAL_TELEMETRY_ONLY',
            'plan_command_sha256': self.session.sha256,
            'verified_command_results': self._verified_results,
            'planned_frames': len(self._goldens),
            'verified_frame_indices': list(self._verified_indices),
            'unverified_frame_indices': missing,
            'full_image_sequence_proven_from_capture': full,
            'physical_hardware_verified': False,
            'capture_source_authenticated': False,
            'sent_wire_physically_observed': False,
            'reset_proven': False,
        })
        # Zero-length result_tags list is by design; correct its inherited count.
        report['result_packets'] = self._verified_results
        return report


def audit_planned_stream(session: CompiledSession, capture: bytes, *, epoch: str,
                         sent_wire: bytes, final_dropped: int,
                         chunk_size: int = 173) -> dict:
    if type(capture) is not bytes:
        raise ValueError('separate binary capture required')
    if type(chunk_size) is not int or not 1 <= chunk_size <= 65536:
        raise ValueError('invalid chunk size')
    audit = PlannedTelemetryAudit(session, epoch=epoch, sent_wire=sent_wire)
    for i in range(0, len(capture), chunk_size):
        audit.feed(capture[i:i + chunk_size])
    return audit.finalize(final_dropped=final_dropped)
