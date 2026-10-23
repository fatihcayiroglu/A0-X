"""P113 intended cycle semantics for progress-aware PRESENT diagnostics.

Python oracle, NOT a substitute for HDL compilation or RTL simulation.
"""
from __future__ import annotations
from dataclasses import dataclass

@dataclass(frozen=True)
class MonitorState:
    state: str
    active_tag: int
    active_present: bool
    last_fault_tag: int
    age: int
    timeouts: int
    tag_mismatches: int
    protocol_faults: int
    completed: int
    present_pixels: int

class ProgressWatchdog:
    def __init__(self, *, max_wait: int=4096):
        if type(max_wait) is not int or not 1 <= max_wait <= 0x7fffffff:
            raise ValueError('max_wait must be 1..2^31-1')
        self.max_wait=max_wait
        self.reset()

    def reset(self):
        self.state='IDLE'
        self.active_tag=0
        self.active_present=False
        self.last_fault_tag=0
        self.age=0
        self.held_error=False
        self.timeouts=0
        self.tag_mismatches=0
        self.protocol_faults=0
        self.completed=0
        self.present_pixels=0
        return self.snapshot()

    def snapshot(self) -> MonitorState:
        return MonitorState(self.state,self.active_tag,self.active_present,
            self.last_fault_tag,self.age,self.timeouts,self.tag_mismatches,
            self.protocol_faults,self.completed,self.present_pixels)

    def _fault(self, counter:str,tag:int):
        setattr(self,counter,min(0xffffffff,getattr(self,counter)+1))
        self.last_fault_tag=tag
        self.state='FAULT'

    def tick(self, *, accepting:bool=False, accepted_tag:int=0,
             opcode:int=0, response_valid:bool=False, response_tag:int=0,
             response_error:bool=False, response_ready:bool=False,
             pixel_valid:bool=False, pixel_ready:bool=False) -> MonitorState:
        for tag in (accepted_tag,response_tag):
            if type(tag) is not int or not 0 <= tag <= 65535:
                raise ValueError('tags must be uint16')
        if type(opcode) is not int or not 0 <= opcode <= 3:
            raise ValueError('opcode must be 0..3')
        for val in (accepting,response_valid,response_error,response_ready,pixel_valid,pixel_ready):
            if type(val) is not bool:
                raise ValueError('handshake flags must be bool')
        if self.state=='IDLE':
            if response_valid:
                self._fault('protocol_faults',response_tag)
            elif accepting:
                self.active_tag=accepted_tag
                self.active_present=(opcode==2)
                self.age=0
                self.present_pixels=0
                self.state='WAIT'
        elif self.state=='WAIT':
            if accepting:
                self._fault('protocol_faults',accepted_tag)
            elif response_valid:
                if response_tag!=self.active_tag:
                    self._fault('tag_mismatches',response_tag)
                elif response_ready:
                    self.completed=min(0xffffffff,self.completed+1)
                    self.state='IDLE'
                else:
                    self.held_error=response_error
                    self.state='HOLD'
            elif self.active_present and pixel_valid:
                if pixel_ready:
                    self.age=0
                    self.present_pixels=min(0xffffffff,self.present_pixels+1)
                # Valid-but-stalled PRESENT pixel freezes the idle timer.
            elif self.age>=self.max_wait-1:
                self._fault('timeouts',self.active_tag)
            else:
                self.age+=1
        elif self.state=='HOLD':
            if (accepting or not response_valid or response_tag!=self.active_tag
                    or response_error!=self.held_error):
                self._fault('protocol_faults',self.active_tag)
            elif response_ready:
                self.completed=min(0xffffffff,self.completed+1)
                self.state='IDLE'
        return self.snapshot()
