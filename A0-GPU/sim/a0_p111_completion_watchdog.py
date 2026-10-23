"""P111 cycle-step behavioral reference for the *diagnostic* RTL only.

No claim of HDL execution: this model is the intended oracle to be compared
against real Icarus/Verilator outputs when a simulator becomes available.
"""
from __future__ import annotations
from dataclasses import dataclass

@dataclass(frozen=True)
class Snapshot:
    state: str
    active_tag: int
    last_fault_tag: int
    timeouts: int
    tag_mismatches: int
    protocol_faults: int
    completed: int
    age: int


class CompletionWatchdog:
    def __init__(self, *, max_wait: int = 4096):
        if type(max_wait) is not int or not 1 <= max_wait <= 0x7fffffff:
            raise ValueError('max_wait must be 1..2^31-1')
        self.max_wait = max_wait
        self.reset()

    def reset(self) -> Snapshot:
        self.state = 'IDLE'
        self.active_tag = 0
        self.last_fault_tag = 0
        self.age = 0
        self.timeouts = 0
        self.tag_mismatches = 0
        self.protocol_faults = 0
        self.completed = 0
        self.held_error = False
        return self.snapshot()

    def snapshot(self) -> Snapshot:
        return Snapshot(self.state, self.active_tag, self.last_fault_tag,
                        self.timeouts, self.tag_mismatches, self.protocol_faults,
                        self.completed, self.age)

    def tick(self, *, accepting: bool = False, accepted_tag: int = 0,
             response_valid: bool = False, response_tag: int = 0,
             response_error: bool = False, response_ready: bool = False) -> Snapshot:
        for tag in (accepted_tag, response_tag):
            if type(tag) is not int or tag < 0 or tag > 65535:
                raise ValueError('tags must be unsigned 16-bit integers')
        for v in (accepting, response_valid, response_error, response_ready):
            if type(v) is not bool:
                raise ValueError('handshake signals must be booleans')
        if self.state == 'IDLE':
            if response_valid:
                self._fault('protocol_faults', response_tag)
            elif accepting:
                self.active_tag, self.age, self.state = accepted_tag, 0, 'WAIT'
        elif self.state == 'WAIT':
            if accepting:
                self._fault('protocol_faults', accepted_tag)
            elif response_valid:
                if response_tag != self.active_tag:
                    self._fault('tag_mismatches', response_tag)
                elif response_ready:
                    self._done()
                else:
                    self.state = 'HOLD'
                    self.held_error = response_error
            elif self.age >= self.max_wait - 1:
                self._fault('timeouts', self.active_tag)
            else:
                self.age += 1
        elif self.state == 'HOLD':
            if (accepting or not response_valid or response_tag != self.active_tag
                    or response_error != self.held_error):
                self._fault('protocol_faults', self.active_tag)
            elif response_ready:
                self._done()
        # FAULT terminal until external reset.
        return self.snapshot()

    def _fault(self, kind: str, tag: int) -> None:
        setattr(self, kind, min(0xffffffff, getattr(self, kind) + 1))
        self.last_fault_tag = tag
        self.state = 'FAULT'

    def _done(self) -> None:
        self.completed = min(0xffffffff, self.completed + 1)
        self.state = 'IDLE'
