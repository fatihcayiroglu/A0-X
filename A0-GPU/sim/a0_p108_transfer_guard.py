"""P108 fail-closed simulated host TX state machine with packet boundaries.

The writer returns how many offered bytes were accepted by the *host transport*;
that is not evidence that hardware received or executed them. Any exception
makes the execution epoch indeterminate, as a writer may consume bytes before
raising. No automatic retry after an ambiguous failure or timeout.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import re
from typing import Callable

from a0_p107_host_batch import CompiledSession, audit_capture

SENDING = 'SENDING'
HOST_ACCEPTED_UNVERIFIED = 'HOST_ACCEPTED_UNVERIFIED'
ABORTED_NO_PROGRESS = 'ABORTED_NO_PROGRESS'
ABORTED_UNCERTAIN = 'ABORTED_UNCERTAIN'
CAPTURE_AUDITED = 'CAPTURE_AUDITED_SOFTWARE_ONLY'


@dataclass(frozen=True)
class TxEvent:
    tick: int
    packet: int
    offset: int
    offered: int
    accepted: int
    prefix_sha256: str


class TransferGuard:
    """One purported reset epoch. Supports *one* forward-only transmission.

    Input ticks are caller-supplied logical ticks, not device time. A returning
    positive count from the writer means host-transport acceptance only. When
    the writer raises, no assumption can be made about hidden side effects.
    """

    def __init__(self, session: CompiledSession, *, epoch: str,
                 reset_acknowledged: bool, max_chunk: int = 16,
                 timeout_ticks: int = 5):
        if not isinstance(session, CompiledSession):
            raise TypeError('compiled session required')
        if type(epoch) is not str or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', epoch):
            raise ValueError('nonempty bounded epoch label required')
        if reset_acknowledged is not True:
            raise ValueError('external reset acknowledgment required before new TX epoch')
        if type(max_chunk) is not int or not 1 <= max_chunk <= 65536:
            raise ValueError('invalid maximum host write size')
        if type(timeout_ticks) is not int or not 1 <= timeout_ticks <= 1_000_000:
            raise ValueError('invalid progress timeout')
        self.session = session
        self.epoch = epoch
        self.max_chunk = max_chunk
        self.timeout_ticks = timeout_ticks
        self.status = SENDING
        self.accepted = 0
        self.events: list[TxEvent] = []
        self.last_tick: int | None = None
        self.last_progress_tick: int | None = None
        self.reason: str | None = None
        self.packet_ends: list[int] = []
        offset = 0
        # The decoder in P106 identifies mixed lengths via the canonical byte
        # header: byte 4 is v1 or v2. Check lengths and exact concatenation.
        for _draw in session.draws:
            # Never infer wire version from semantic defaults (v2 may encode
            # default fragment state). Read actual wire version instead.
            version = session.wire[offset + 4]
            if version not in (1, 2):
                raise ValueError('noncanonical command frame version')
            offset += 32 if version == 1 else 56
            self.packet_ends.append(offset)
        if offset != len(session.wire) or not session.wire:
            raise ValueError('session has inconsistent canonical wire lengths')

    def _tick(self, tick: int) -> None:
        if type(tick) is not int or tick < 0:
            raise ValueError('nonnegative integer monotonic logical tick required')
        if self.last_tick is not None and tick <= self.last_tick:
            raise ValueError('ticks must increase strictly')
        self.last_tick = tick
        if self.last_progress_tick is None:
            self.last_progress_tick = tick

    def poll(self, tick: int, writer: Callable[[bytes], int]) -> str:
        """Offer bytes from *one* command frame; never splice frames in one write.

        On writer exception or invalid count, the attempted slice's fate is
        unknown; this epoch must not be resumed or replayed automatically.
        """
        if self.status != SENDING:
            raise RuntimeError('transfer is terminal; fresh external reset epoch required')
        if not callable(writer):
            raise TypeError('writer callable required')
        self._tick(tick)
        assert self.last_progress_tick is not None
        if tick - self.last_progress_tick >= self.timeout_ticks:
            self._abort('progress timeout before attempting next write', uncertain=self.accepted > 0)
            return self.status
        packet = next(i for i, stop in enumerate(self.packet_ends) if self.accepted < stop)
        end = self.packet_ends[packet]
        offset = self.accepted
        fragment = self.session.wire[offset:min(end, offset + self.max_chunk)]
        try:
            n = writer(fragment)
        except Exception as exc:
            self._abort(f'writer exception ({type(exc).__name__}); side effects unknown', uncertain=True)
            return self.status
        if type(n) is not int or not 0 <= n <= len(fragment):
            self._abort('writer returned invalid count; side effects unknown', uncertain=True)
            return self.status
        if n:
            self.accepted += n
            self.last_progress_tick = tick
            self.events.append(TxEvent(tick, packet, offset, len(fragment), n,
                           hashlib.sha256(self.session.wire[:self.accepted]).hexdigest()))
        if self.accepted == len(self.session.wire):
            self.status = HOST_ACCEPTED_UNVERIFIED
        return self.status

    def _abort(self, reason: str, *, uncertain: bool) -> None:
        self.reason = reason
        self.status = ABORTED_UNCERTAIN if uncertain else ABORTED_NO_PROGRESS

    def audit(self, capture: bytes) -> dict:
        if self.status != HOST_ACCEPTED_UNVERIFIED:
            raise RuntimeError('capture audit requires full host write acceptance')
        result = audit_capture(self.session, capture, sent_wire=self.session.wire)
        self.status = CAPTURE_AUDITED
        return {**result, 'transport_state':self.status,
                'hardware_execution_proven':False,
                'device_reset_proven':False}

    def receipt(self) -> dict:
        return {
            'schema':'A0-P108-TRANSFER-RECEIPT-v1',
            'epoch':self.epoch,
            'reset_acknowledged_by_caller_not_verified':True,
            'state':self.status,
            'reason':self.reason,
            'planned_bytes':len(self.session.wire),
            'host_accepted_bytes':self.accepted,
            'planned_sha256':self.session.sha256,
            'accepted_prefix_sha256':hashlib.sha256(self.session.wire[:self.accepted]).hexdigest(),
            'events':[event.__dict__ for event in self.events],
            'can_resume_without_fresh_reset':self.status == SENDING,
            'automatic_replay_permitted':False,
            'hardware_execution_proven':False,
            'device_reset_proven':False,
        }


def verify_receipt(session: CompiledSession, receipt: dict) -> dict:
    """Check a P108 *unsigned* receipt for internal consistency only.

    A forger able to modify the receipt can also recompute the hashes. This
    does NOT verify provenance, a real reset, device acceptance or execution.
    """
    if not isinstance(session, CompiledSession) or type(receipt) is not dict:
        raise ValueError('compiled session and receipt object required')
    expected = {'schema','epoch','reset_acknowledged_by_caller_not_verified',
       'state','reason','planned_bytes','host_accepted_bytes','planned_sha256',
       'accepted_prefix_sha256','events','can_resume_without_fresh_reset',
       'automatic_replay_permitted','hardware_execution_proven','device_reset_proven'}
    # CLI receipts optionally add the evidence kind and capture audit.
    if not expected <= set(receipt) or set(receipt) - expected - {'evidence_kind','capture_audit'}:
        raise ValueError('receipt has missing or unexpected fields')
    if receipt['schema'] != 'A0-P108-TRANSFER-RECEIPT-v1' or \
       type(receipt['epoch']) is not str or not re.fullmatch(
           r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', receipt['epoch']):
        raise ValueError('invalid receipt schema/epoch')
    if receipt['reset_acknowledged_by_caller_not_verified'] is not True or \
       receipt['hardware_execution_proven'] is not False or \
       receipt['device_reset_proven'] is not False or \
       receipt['automatic_replay_permitted'] is not False:
        raise ValueError('unsupported proof or replay claim')
    if type(receipt['planned_bytes']) is not int or receipt['planned_bytes'] != len(session.wire) or \
       receipt['planned_sha256'] != session.sha256:
        raise ValueError('plan bytes/digest mismatch')
    events = receipt['events']
    if type(events) is not list or len(events) > len(session.wire):
        raise ValueError('invalid receipt event count')
    offset, last_tick = 0, -1
    packet_ends=[]
    for d in session.draws:
        v=session.wire[(packet_ends[-1] if packet_ends else 0)+4]
        packet_ends.append((packet_ends[-1] if packet_ends else 0)+(32 if v==1 else 56))
    if not packet_ends or packet_ends[-1] != len(session.wire):
        raise ValueError('invalid session command boundaries')
    for event in events:
        if type(event) is not dict or set(event) != {
            'tick','packet','offset','offered','accepted','prefix_sha256'}:
            raise ValueError('invalid receipt event schema')
        tick=event['tick']; got=event['accepted']; offered=event['offered']
        if type(tick) is not int or tick <= last_tick or \
           any(type(event[key]) is not int for key in ('packet','offset','offered','accepted')):
            raise ValueError('receipt tick or integer field invalid')
        if tick < 0 or not 1 <= got <= offered or \
           event['offset'] != offset:
            raise ValueError('receipt write offsets/counts invalid')
        pi=next((i for i,end in enumerate(packet_ends) if offset < end),None)
        if pi is None or event['packet'] != pi or offered > packet_ends[pi]-offset:
            raise ValueError('receipt crosses packet boundary')
        offset += got
        if event['prefix_sha256'] != hashlib.sha256(session.wire[:offset]).hexdigest():
            raise ValueError('receipt accepted prefix digest mismatch')
        last_tick=tick
    if type(receipt['host_accepted_bytes']) is not int or receipt['host_accepted_bytes'] != offset or \
       receipt['accepted_prefix_sha256'] != hashlib.sha256(session.wire[:offset]).hexdigest():
        raise ValueError('receipt final offset/hash mismatch')
    state=receipt['state']
    if state not in (SENDING,HOST_ACCEPTED_UNVERIFIED,ABORTED_NO_PROGRESS,
                     ABORTED_UNCERTAIN,CAPTURE_AUDITED):
        raise ValueError('unknown receipt state')
    if (state in (HOST_ACCEPTED_UNVERIFIED,CAPTURE_AUDITED)) != (offset == len(session.wire)):
        raise ValueError('terminal complete state inconsistent with accepted bytes')
    if state == ABORTED_NO_PROGRESS and offset != 0:
        raise ValueError('no-progress status but bytes accepted')
    if receipt['can_resume_without_fresh_reset'] is not (state == SENDING):
        raise ValueError('resume flag incorrect')
    if (state in (ABORTED_NO_PROGRESS,ABORTED_UNCERTAIN)) != (type(receipt['reason']) is str):
        raise ValueError('terminal reason inconsistent')
    if 'evidence_kind' in receipt and receipt['evidence_kind'] != \
       'OFFLINE_SCRIPTED_SIMULATION_NOT_HOST_CAPTURE':
        raise ValueError('invalid offline evidence marker')
    if 'capture_audit' in receipt and (type(receipt['capture_audit']) is not dict or
         receipt['capture_audit'].get('status') not in ('PASS','FAIL')):
        raise ValueError('malformed supplementary capture audit')
    return {'status':'PASS','internally_consistent':True,
            'accepted_bytes':offset,'provenance_verified':False,
            'hardware_execution_proven':False}
