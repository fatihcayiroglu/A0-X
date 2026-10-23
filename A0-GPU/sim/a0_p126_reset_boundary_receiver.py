"""P126 explicit-reset host stream isolation (software, not hardware evidence).

Each transport reset closes the preceding receive epoch, including any partial
32-byte packet, WITHOUT treating that old epoch as successfully reconciled.
The caller must supply a fresh, out-of-band reset acknowledgment; this code
can enforce that a claim was supplied, not independently authenticate it.
In particular, CRC32 alone is never proof of transport, device, or reset.
"""
from __future__ import annotations

import copy
import re

from a0_p119_epoch_reconcile import EpochReconciler

_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")


def _label(v: str, field: str) -> str:
    if type(v) is not str or _ID.fullmatch(v) is None:
        raise ValueError(f'{field} must be a bounded nonempty audit identifier')
    return v


class ResetBoundaryReceiver:
    """Keep byte-stream epochs isolated across acknowledged external resets.

    reset_boundary must only be called AFTER the transport has actually
    observed asserted device reset and TX quiescence. The report explicitly
    does NOT validate the caller's assertion. This is an integration guard,
    not a secure attestation or FPGA/RTL qualification.
    """

    def __init__(self, epoch: str):
        self._epoch_id = _label(epoch, 'initial epoch')
        self._reconciler = EpochReconciler(self._epoch_id)
        self._seen_epochs = {self._epoch_id}
        self._seen_evidence = set()
        self._boundary_index = 0
        self._aborted = []
        self._closed = False
        self._poisoned = False

    def feed(self, data: bytes) -> None:
        if self._closed or self._poisoned:
            raise ValueError('receiver closed or invalidated')
        try:
            self._reconciler.feed(data)
        except (ValueError, TypeError):
            self._poisoned = True
            raise

    def reset_boundary(self, *, new_epoch: str, evidence_id: str,
                       boundary_index: int, reset_asserted: bool,
                       transmitter_quiesced: bool) -> dict:
        """Discard only the previous epoch's unfinished tail, then restart.

        evidence_id is an audit reference; caller-authored evidence is NOT
        independently checked, so the report must never claim reset_proven.
        """
        if self._closed or self._poisoned:
            raise ValueError('receiver closed or invalidated')
        # Any malformed attempt is rejected before mutating the old epoch.
        epoch = _label(new_epoch, 'new epoch')
        evidence = _label(evidence_id, 'reset evidence id')
        if epoch in self._seen_epochs:
            raise ValueError('epoch replay or reuse')
        if evidence in self._seen_evidence:
            raise ValueError('reset evidence replay')
        if type(boundary_index) is not int or boundary_index != self._boundary_index + 1:
            raise ValueError('reset boundary must advance by exactly one')
        if reset_asserted is not True or transmitter_quiesced is not True:
            raise ValueError('external reset and transmitter-quiescence acknowledgments required')
        old = self._reconciler
        discarded = bytes(old._buffer)
        entry = {
            'status': 'PREVIOUS_EPOCH_ABORTED',
            'previous_epoch': self._epoch_id,
            'new_epoch': epoch,
            'boundary_index': boundary_index,
            'external_evidence_reference': evidence,
            'reset_and_quiescence_claimed_by_caller': True,
            'device_reset_authenticated': False,
            'physical_hardware_verified': False,
            'completed_packets_before_abort': old.total_packets,
            'received_bytes_before_abort': old.total_bytes,
            'discarded_partial_bytes': len(discarded),
            'discarded_partial_hex': discarded.hex(),
            'previous_capture_sha256': old._digest.hexdigest(),
            'previous_epoch_reconciled': False,
        }
        self._aborted.append(entry)
        self._seen_epochs.add(epoch)
        self._seen_evidence.add(evidence)
        self._boundary_index = boundary_index
        self._epoch_id = epoch
        # Crucially no bytes, counters, sequence, or CRC state carry over.
        self._reconciler = EpochReconciler(epoch)
        return copy.deepcopy(entry)

    def finalize(self, *, final_attempted: int, final_dropped: int,
                 expected_result_tags: list[int] | None = None) -> dict:
        if self._closed or self._poisoned:
            raise ValueError('receiver closed or invalidated')
        self._closed = True
        # Failure remains terminal rather than permitting post-hoc repair.
        latest = self._reconciler.finalize(
            final_attempted=final_attempted, final_dropped=final_dropped,
            expected_result_tags=expected_result_tags)
        return {
            'schema': 'A0-P126-EXPLICIT-RESET-RECEIVER-1',
            'status': 'LATEST_EPOCH_SOFTWARE_STREAM_CONSISTENT',
            'latest': latest,
            'aborted_epochs': copy.deepcopy(self._aborted),
            'aborted_epoch_count': len(self._aborted),
            'all_epochs_reconciled': not self._aborted,
            'reset_proven': False,
            'physical_hardware_verified': False,
            'external_counters_authenticated': False,
        }
