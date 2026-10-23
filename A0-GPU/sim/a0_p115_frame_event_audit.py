"""P115 independent software intent model, NOT SystemVerilog execution.

Samples registered P42 frame_done, registered P47 frame_valid and P114
liveness completed counter in the same logical clock. After matching event,
expects liveness counter to advance by the following sampled clock. A matched
CRC merely means internal monitors agree, not end-to-end image authentication.
"""
from dataclasses import dataclass

MAX=(1<<32)-1

@dataclass(frozen=True)
class AuditSnapshot:
    fault:bool
    pending:bool
    good:int
    untrusted:int
    event_faults:int
    crc_errors:int
    liveness_faults:int
    telemetry_lost:int
    last_crc:int

class FrameEventAudit:
    def __init__(self):self.reset()
    def reset(self):
        self.fault=False;self.pending=False;self.expected=0;self.clean=False
        self.good=0;self.untrusted=0;self.event_faults=0;self.crc_errors=0
        self.liveness_faults=0;self.telemetry_lost=0;self.last_crc=0
        self.previous_liveness_fault=False;self.previous_telemetry_drop=0
    def tick(self,*,active=False,done=False,crc_valid=False,crc_error=False,
             crc=0,liveness_pending=False,liveness_fault=False,
             liveness_completed=0,telemetry_dropped=0):
        for k,v in locals().copy().items():
            if k in ('self','crc','liveness_completed','telemetry_dropped'):continue
            if type(v) is not bool:raise ValueError(f'{k}: expected bool')
        for k,v in [('crc',crc),('liveness_completed',liveness_completed),
                    ('telemetry_dropped',telemetry_dropped)]:
            if type(v) is not int or not 0<=v<=MAX:raise ValueError(f'{k}: expected uint32')
        if liveness_fault and not self.previous_liveness_fault:
            self.fault=True;self.liveness_faults=min(MAX,self.liveness_faults+1)
        self.previous_liveness_fault=liveness_fault
        if telemetry_dropped!=self.previous_telemetry_drop:
            self.fault=True
            if telemetry_dropped>self.previous_telemetry_drop:
                self.telemetry_lost=min(MAX,self.telemetry_lost+telemetry_dropped-self.previous_telemetry_drop)
            else:self.event_faults=min(MAX,self.event_faults+1)
            self.previous_telemetry_drop=telemetry_dropped
        old_pending=self.pending
        if old_pending:
            self.pending=False
            if liveness_completed!=self.expected or liveness_fault:
                self.fault=True;self.event_faults=min(MAX,self.event_faults+1)
                self.untrusted=min(MAX,self.untrusted+1)
            elif self.clean:self.good=min(MAX,self.good+1)
            else:self.untrusted=min(MAX,self.untrusted+1)
        if done or crc_valid:
            if not(done and crc_valid and active and liveness_pending and not liveness_fault and not old_pending):
                self.fault=True
                self.event_faults=min(MAX,self.event_faults+1)
                self.untrusted=min(MAX,self.untrusted+1)
            else:
                self.pending=True
                self.expected=min(MAX,liveness_completed+1)
                self.clean=not crc_error
                self.last_crc=crc
                if crc_error:
                    self.fault=True
                    self.crc_errors=min(MAX,self.crc_errors+1)
    def snapshot(self):
        return AuditSnapshot(self.fault,self.pending,self.good,self.untrusted,
            self.event_faults,self.crc_errors,self.liveness_faults,self.telemetry_lost,self.last_crc)
