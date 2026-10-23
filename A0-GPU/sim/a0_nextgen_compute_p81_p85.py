"""P81-P85 bounded SIMT-ish compute SOFTWARE interpreter (not hardware)."""
from dataclasses import dataclass


class ComputeFault(ValueError):
    pass


@dataclass(frozen=True)
class Kernel:
    code: tuple  # sequence of (op, dst, a, b)
    lanes: int = 8

    def __post_init__(self):
        if type(self.lanes) is not int or not 1 <= self.lanes <= 32:
            raise ComputeFault('lane count out of bounds')
        if not 1 <= len(self.code) <= 64:
            raise ComputeFault('instruction budget exceeded')
        for step in self.code:
            if len(step) != 4 or step[0] not in ('LOAD','STORE','ADD','MUL','MOV','BARRIER','GROUP_SUM'):
                raise ComputeFault('bad kernel instruction')
            if any(type(i) is not int or not 0 <= i < 8 for i in step[1:]):
                raise ComputeFault('register index invalid')


@dataclass(frozen=True)
class ComputeResult:
    data: tuple
    executed_lanes: int
    barriers: int
    workgroups: int


def dispatch(kernel: Kernel, values, *, workgroups=1, active_mask=None):
    """Lockstep, bounded per-workgroup kernel. Memory is a private copy.

    Each lane exposes r0=global id, r1=local id, r2=workgroup id.
    LOAD and STORE address memory by register a. GROUP_SUM broadcasts the
    active group register a sum; barriers count uniformly across the group.
    Inactive lanes have no register or memory side effects.
    """
    if type(workgroups) is not int or not 1 <= workgroups <= 4096:
        raise ComputeFault('invalid workgroup count')
    if active_mask is None: active_mask=(1<<kernel.lanes)-1
    if type(active_mask) is not int or active_mask<0 or active_mask >= 1<<kernel.lanes:
        raise ComputeFault('invalid active mask')
    if len(values)>1048576 or any(type(v) is not int or not -(1<<31)<=v<(1<<31) for v in values):
        raise ComputeFault('memory must contain signed int32')
    mem=list(values)
    launched=0; barriers=0
    for group in range(workgroups):
        regs=[]
        for lane in range(kernel.lanes):
            rid=group*kernel.lanes+lane
            regs.append([rid,lane,group,0,0,0,0,0])
        live=[lane for lane in range(kernel.lanes) if (active_mask>>lane)&1]
        launched+=len(live)
        for op,dst,a,b in kernel.code:
            if op=='BARRIER':
                barriers+=1
                continue
            if op=='GROUP_SUM':
                aggregate=sum(regs[lane][a] for lane in live)
                if not -(1<<31)<=aggregate<(1<<31):raise ComputeFault('group sum overflow')
                for lane in live:regs[lane][dst]=aggregate
                continue
            for lane in live:
                r=regs[lane]
                if op in ('LOAD','STORE'):
                    address=r[a]
                    if not 0<=address<len(mem):
                        raise ComputeFault('out of bounds global memory')
                    if op=='LOAD':r[dst]=mem[address]
                    else: mem[address]=r[b]
                else:
                    n=(r[a]+r[b]) if op=='ADD' else (r[a]*r[b]) if op=='MUL' else r[a]
                    if not -(1<<31)<=n<(1<<31):raise ComputeFault('int32 overflow')
                    r[dst]=n
    return ComputeResult(tuple(mem),launched,barriers,workgroups)
