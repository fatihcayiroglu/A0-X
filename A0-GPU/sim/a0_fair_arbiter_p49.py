"""P49 SOFTWARE reference for complete-frame two-lane round robin. NOT RTL."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Edge:
    lane: str | None
    valid: bool
    byte: int | None
    result_ready: bool
    telemetry_ready: bool
    transferred: bool


class FairArbiter:
    def __init__(self):
        self.reset()

    def reset(self):
        self.lane = None
        self.index = 0
        self.prefer_telemetry = False

    def tick(self, *, result_valid=False, result_byte=0,
             telemetry_valid=False, telemetry_byte=0,
             host_ready=False, rst_n=True):
        if not rst_n:
            self.reset()
            return Edge(None,False,None,False,False,False)
        lane = self.lane
        valid = (result_valid if lane == 'result' else
                 telemetry_valid if lane == 'telemetry' else False)
        byte = (result_byte if lane == 'result' else
                telemetry_byte if lane == 'telemetry' else None)
        rr = lane == 'result' and bool(host_ready)
        tr = lane == 'telemetry' and bool(host_ready)
        sent = bool(valid and host_ready)
        if lane is None:
            if result_valid and telemetry_valid:
                self.lane = 'telemetry' if self.prefer_telemetry else 'result'
            elif result_valid:
                self.lane = 'result'
            elif telemetry_valid:
                self.lane = 'telemetry'
        elif sent:
            self.index += 1
            if self.index == (16 if lane == 'result' else 32):
                self.lane = None
                self.index = 0
                self.prefer_telemetry = lane == 'result'
        return Edge(lane,bool(valid),byte if valid else None,bool(rr),bool(tr),sent)
