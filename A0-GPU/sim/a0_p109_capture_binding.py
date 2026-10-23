"""P109 offline independent three-artifact attestation; NOT physical provenance.

Do not trust claims in P108 receipts: re-run the P107 host capture audit over
explicitly supplied capture bytes and explicitly supplied attempted TX bytes.
This is evidence consistency, NOT signature verification, proof of device reset,
proof of hardware execution, or PCIe/USB/FPGA access.
"""
from __future__ import annotations

from hashlib import sha256
import re
from typing import Any

from a0_p107_host_batch import CompiledSession, audit_capture
from a0_p108_transfer_guard import CAPTURE_AUDITED, verify_receipt

MAX_SESSIONS = 128


def verify_capture_binding(session: CompiledSession, receipt: dict,
                           capture: bytes, sent_wire: bytes) -> dict:
    """Verify actual input bytes and strict capture evidence; reject self-attestation.

    Requires a *previously captured* result stream (never synthesized from the
    alleged success receipt) and original transmitted host byte stream. The
    independently supplied expected frame CRCs come from CompiledSession.
    """
    if not isinstance(session, CompiledSession):
        raise ValueError('compiled host session required')
    if type(capture) is not bytes or type(sent_wire) is not bytes:
        raise ValueError('separate binary capture and sent-wire files required')
    if type(receipt) is not dict:
        raise ValueError('P108 receipt object required')
    verification = verify_receipt(session, receipt)
    if verification['status'] != 'PASS':
        raise ValueError('P108 receipt inconsistency')
    if receipt['state'] != CAPTURE_AUDITED:
        raise ValueError('receipt is not in fully audited state')
    if receipt['host_accepted_bytes'] != len(session.wire):
        raise ValueError('incomplete host byte acceptance')
    if 'capture_audit' not in receipt:
        raise ValueError('audited receipt lacks capture audit record')
    if sent_wire != session.wire:
        raise ValueError('sent host byte file differs from planned commands')
    # Compare every audit field, including its explicitly limited proof claims.
    freshly_audited = audit_capture(session, capture, sent_wire=sent_wire)
    expected = {**freshly_audited,
                'transport_state': CAPTURE_AUDITED,
                'hardware_execution_proven': False,
                'device_reset_proven': False}
    if type(receipt['capture_audit']) is not dict or receipt['capture_audit'] != expected:
        raise ValueError('receipt capture audit is unbound to supplied capture')
    return {
        'schema': 'A0-P109-EVIDENCE-CONSISTENCY-v1',
        'status': 'PASS',
        'epoch': receipt['epoch'],
        'commands': freshly_audited['commands'],
        'frames': freshly_audited['frames'],
        'host_accepted_bytes': receipt['host_accepted_bytes'],
        'sent_wire_sha256': sha256(sent_wire).hexdigest(),
        'capture_sha256': sha256(capture).hexdigest(),
        'receipt_state': receipt['state'],
        'capture_consistent_with_supplied_goldens': True,
        'receipt_consistent_with_supplied_artifacts': True,
        'hardware_execution_proven': False,
        'physical_capture_provenance_verified': False,
        'physical_reset_proven': False,
        'exactly_once_execution_proven': False,
    }


def verify_epoch_batch(items: list[tuple[CompiledSession, dict, bytes, bytes]]) -> dict:
    """Check multiple locally labeled epochs, rejecting duplicate labels.

    Epoch uniqueness only within this supplied list; a forged label is not
    proof that a physical device was reset between batches.
    """
    if type(items) is not list or not 1 <= len(items) <= MAX_SESSIONS:
        raise ValueError('expected 1..128 session evidence tuples')
    seen: set[str] = set()
    out = []
    for i, entry in enumerate(items):
        if type(entry) is not tuple or len(entry) != 4:
            raise ValueError(f'entry {i} must have plan, receipt, capture, wire')
        session, receipt, capture, sent_wire = entry
        if type(receipt) is not dict:
            raise ValueError('receipt must be a mapping')
        epoch = receipt.get('epoch')
        if type(epoch) is not str or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', epoch):
            raise ValueError('invalid reset epoch label')
        if epoch in seen:
            raise ValueError(f'duplicate reset epoch label in bundle: {epoch}')
        seen.add(epoch)
        out.append(verify_capture_binding(session, receipt, capture, sent_wire))
    return {'schema': 'A0-P109-BATCH-CONSISTENCY-v1', 'status':'PASS',
            'sessions': len(out), 'records':out,
            'physical_reset_proven':False, 'hardware_execution_proven':False}
