#!/usr/bin/env python3
"""A0 SIM16: deterministic non-blocking memory / MSHR timing study model.

This is a research timing model, not an architectural replacement for A0GPU.
It intentionally models a future non-blocking LSU where a wave may advance
past an issued load when the next instruction is independent of that load.

Key modeled mechanisms:
- single instruction issue per cycle across all resident waves,
- in-order per-wave instruction stream,
- register RAW/WAW readiness,
- configurable MSHR capacity,
- one MSHR per distinct outstanding L2 miss line,
- same-line miss merging,
- finite LRU L2 capacity,
- fixed L2-hit and DRAM-miss latency,
- LRR, GTO, oldest-ready, SIM15 a0_adaptive_v0, and SIM17 a0_adaptive_v1 scheduler policies.

Important limitation:
DRAM channel/bank contention and return bandwidth are not modeled yet.
Therefore the MSHR-capacity result is an upper-bound timing study and must not
be treated as a final hardware sizing decision.
"""

from __future__ import annotations

from collections import OrderedDict, defaultdict
from dataclasses import dataclass, field
from math import ceil
from typing import Iterable


@dataclass(frozen=True)
class Instruction:
    kind: str
    dst: int | None = None
    srcs: tuple[int, ...] = ()
    line: int | None = None
    latency: int = 1

    @staticmethod
    def load(dst: int, line: int) -> "Instruction":
        return Instruction("mem", dst=dst, line=line)

    @staticmethod
    def alu(
        dst: int | None = None,
        srcs: tuple[int, ...] = (),
        latency: int = 1,
    ) -> "Instruction":
        return Instruction("alu", dst=dst, srcs=srcs, latency=latency)

    @staticmethod
    def halt() -> "Instruction":
        return Instruction("halt")


@dataclass
class WaveState:
    wave_id: int
    program: list[Instruction]
    pc: int = 0
    pending_regs: dict[int, int] = field(default_factory=dict)
    halted: bool = False
    completion_cycle: int | None = None
    issued_instructions: int = 0
    memory_instructions: int = 0
    last_issue_cycle: int = -1

    @property
    def next_instruction(self) -> Instruction:
        return self.program[self.pc]


@dataclass(frozen=True)
class MLPConfig:
    mshr_capacity: int
    l2_capacity_lines: int = 8
    dram_latency: int = 40
    l2_hit_latency: int = 6
    scheduler_policy: str = "lrr"

    def validate(self) -> None:
        if self.mshr_capacity <= 0:
            raise ValueError("mshr_capacity must be positive")
        if self.l2_capacity_lines < 0:
            raise ValueError("l2_capacity_lines must be non-negative")
        if self.dram_latency <= 0:
            raise ValueError("dram_latency must be positive")
        if self.l2_hit_latency <= 0:
            raise ValueError("l2_hit_latency must be positive")
        if self.scheduler_policy not in {
            "lrr",
            "gto",
            "oldest_ready",
            "a0_adaptive_v0",
            "a0_adaptive_v1",
        }:
            raise ValueError(
                f"unsupported scheduler policy: {self.scheduler_policy}"
            )


@dataclass
class _MissEntry:
    done_cycle: int
    waiters: list[tuple[int, int | None]]


@dataclass(frozen=True)
class MLPResult:
    cycles: int
    issued_instructions: int
    memory_instructions: int
    ipc: float
    dram_misses: int
    l2_hits: int
    mshr_merges: int
    mshr_full_global_cycles: int
    mshr_full_wave_cycles: int
    dependency_wave_cycles: int
    average_mshr_occupancy: float
    peak_mshr_occupancy: int
    scheduler_switches: int
    p95_wave_completion: int
    instruction_signature: tuple[int, ...]
    memory_signature: tuple[int, ...]
    adaptive_merge_choices: int
    adaptive_locality_choices: int
    adaptive_fallback_choices: int


class NonBlockingMemoryStudy:
    def __init__(
        self,
        programs: Iterable[list[Instruction]],
        config: MLPConfig,
    ) -> None:
        config.validate()
        self.config = config
        self.waves = [
            WaveState(wave_id=index, program=list(program))
            for index, program in enumerate(programs)
        ]
        if not self.waves:
            raise ValueError("at least one wave is required")
        for wave in self.waves:
            if not wave.program or wave.program[-1].kind != "halt":
                raise ValueError("every program must terminate with HALT")

        self.cycle = 0
        self.last_issued_wave: int | None = None
        self.rr_cursor = 0

        self.mshrs: dict[int, _MissEntry] = {}
        self.miss_completions: dict[int, list[int]] = defaultdict(list)
        self.reg_completions: dict[
            int,
            list[tuple[int, int]],
        ] = defaultdict(list)
        self.l2: OrderedDict[int, None] = OrderedDict()

        self.working_set_lines = len(
            {
                inst.line
                for wave in self.waves
                for inst in wave.program
                if inst.kind == "mem"
            }
        )

        self.issued_instructions = 0
        self.memory_instructions = 0
        self.dram_misses = 0
        self.l2_hits = 0
        self.mshr_merges = 0
        self.mshr_full_global_cycles = 0
        self.mshr_full_wave_cycles = 0
        self.dependency_wave_cycles = 0
        self.mshr_occupancy_sum = 0
        self.peak_mshr_occupancy = 0
        self.scheduler_switches = 0
        self.adaptive_merge_choices = 0
        self.adaptive_locality_choices = 0
        self.adaptive_fallback_choices = 0

    def _touch_l2(self, line: int) -> None:
        if self.config.l2_capacity_lines == 0:
            return
        if line in self.l2:
            self.l2.move_to_end(line)
        else:
            self.l2[line] = None
        while len(self.l2) > self.config.l2_capacity_lines:
            self.l2.popitem(last=False)

    def _complete_cycle(self) -> None:
        for wave_id, reg in self.reg_completions.pop(self.cycle, []):
            wave = self.waves[wave_id]
            if wave.pending_regs.get(reg) == self.cycle:
                del wave.pending_regs[reg]

        for line in self.miss_completions.pop(self.cycle, []):
            entry = self.mshrs.pop(line)
            self._touch_l2(line)
            for wave_id, reg in entry.waiters:
                if reg is None:
                    continue
                wave = self.waves[wave_id]
                if wave.pending_regs.get(reg) == self.cycle:
                    del wave.pending_regs[reg]

    def _destination_blocked(
        self,
        wave: WaveState,
        inst: Instruction,
    ) -> bool:
        if inst.dst is None:
            return False
        return wave.pending_regs.get(inst.dst, -1) > self.cycle

    def _read_dependency_blocked(
        self,
        wave: WaveState,
        inst: Instruction,
    ) -> bool:
        return any(
            wave.pending_regs.get(reg, -1) > self.cycle
            for reg in inst.srcs
        )

    def _ready_reason(
        self,
        wave: WaveState,
    ) -> tuple[bool, str | None]:
        if wave.halted:
            return False, "halted"

        inst = wave.next_instruction

        if self._read_dependency_blocked(wave, inst):
            return False, "dependency"

        if self._destination_blocked(wave, inst):
            return False, "dependency"

        if inst.kind == "halt" and wave.pending_regs:
            return False, "dependency"

        if inst.kind == "mem":
            assert inst.line is not None
            if inst.line in self.l2:
                return True, None
            if inst.line in self.mshrs:
                return True, None
            if len(self.mshrs) >= self.config.mshr_capacity:
                return False, "mshr"

        return True, None

    def _next_is_memory(self, wave: WaveState) -> bool:
        return (
            not wave.halted
            and wave.next_instruction.kind == "mem"
        )

    def _choose_lrr(
        self,
        ready: list[WaveState],
    ) -> WaveState:
        ready_by_id = {wave.wave_id: wave for wave in ready}
        count = len(self.waves)
        for offset in range(count):
            candidate = (self.rr_cursor + offset) % count
            if candidate in ready_by_id:
                self.rr_cursor = (candidate + 1) % count
                return ready_by_id[candidate]
        raise RuntimeError("LRR chooser received no selectable wave")

    def _choose_oldest_ready(
        self,
        ready: list[WaveState],
    ) -> WaveState:
        return min(
            ready,
            key=lambda wave: (
                wave.last_issue_cycle,
                wave.wave_id,
            ),
        )

    def _choose_wave(
        self,
        ready: list[WaveState],
    ) -> WaveState:
        policy = self.config.scheduler_policy

        if policy == "lrr":
            return self._choose_lrr(ready)

        if policy == "oldest_ready":
            return self._choose_oldest_ready(ready)

        if policy == "gto":
            if self.last_issued_wave is not None:
                for wave in ready:
                    if wave.wave_id == self.last_issued_wave:
                        return wave
            return self._choose_oldest_ready(ready)

        # SIM15 a0_adaptive_v0 is intentionally carried forward without
        # MSHR-pressure awareness so SIM16 can determine whether it remains
        # robust once non-blocking memory is introduced.
        if policy == "a0_adaptive_v0":
            if (
                self.working_set_lines
                > self.config.l2_capacity_lines
                and self.last_issued_wave is not None
            ):
                for wave in ready:
                    if (
                        wave.wave_id == self.last_issued_wave
                        and self._next_is_memory(wave)
                    ):
                        return wave
            return self._choose_lrr(ready)

        if policy == "a0_adaptive_v1":
            pressure = (
                len(self.mshrs)
                / self.config.mshr_capacity
            )
            memory_stalled_waves = sum(
                1
                for wave in self.waves
                if self._ready_reason(wave)
                == (False, "mshr")
            )
            merge_ready = [
                wave
                for wave in ready
                if (
                    wave.next_instruction.kind == "mem"
                    and wave.next_instruction.line in self.mshrs
                )
            ]

            # A same-line merge consumes no additional MSHR. Under
            # meaningful MSHR pressure (or when a wave is already
            # capacity-stalled), issue a merge-ready wave before
            # consuming another miss slot.
            if merge_ready and (
                pressure >= 0.5
                or memory_stalled_waves > 0
            ):
                self.adaptive_merge_choices += 1
                return self._choose_lrr(merge_ready)

            # SIM16 showed that unrestricted locality-greedy behavior
            # can regress at small MSHR counts. v1 therefore allows
            # greedy continuation only for a real memory burst and only
            # in the pressure-sensitive <=8-entry prototype region.
            if (
                self.config.mshr_capacity <= 8
                and self.working_set_lines
                > self.config.l2_capacity_lines
                and self.last_issued_wave is not None
            ):
                for wave in ready:
                    previous_kind = (
                        wave.program[wave.pc - 1].kind
                        if wave.pc > 0
                        else None
                    )
                    if (
                        wave.wave_id == self.last_issued_wave
                        and wave.next_instruction.kind == "mem"
                        and previous_kind == "mem"
                    ):
                        self.adaptive_locality_choices += 1
                        return wave

            self.adaptive_fallback_choices += 1
            return self._choose_lrr(ready)

        raise AssertionError("validated policy fell through")

    def _schedule_reg_completion(
        self,
        wave: WaveState,
        reg: int,
        done_cycle: int,
    ) -> None:
        wave.pending_regs[reg] = done_cycle
        self.reg_completions[done_cycle].append(
            (wave.wave_id, reg)
        )

    def _issue_memory(
        self,
        wave: WaveState,
        inst: Instruction,
    ) -> None:
        assert inst.line is not None

        self.memory_instructions += 1
        wave.memory_instructions += 1

        line = inst.line

        if line in self.l2:
            self.l2_hits += 1
            self._touch_l2(line)
            if inst.dst is not None:
                self._schedule_reg_completion(
                    wave,
                    inst.dst,
                    self.cycle + self.config.l2_hit_latency,
                )
            return

        if line in self.mshrs:
            self.mshr_merges += 1
            entry = self.mshrs[line]
            entry.waiters.append(
                (wave.wave_id, inst.dst)
            )
            if inst.dst is not None:
                wave.pending_regs[inst.dst] = entry.done_cycle
            return

        if len(self.mshrs) >= self.config.mshr_capacity:
            raise AssertionError(
                "memory instruction issued without an available MSHR"
            )

        self.dram_misses += 1
        done_cycle = self.cycle + self.config.dram_latency
        entry = _MissEntry(
            done_cycle=done_cycle,
            waiters=[(wave.wave_id, inst.dst)],
        )
        self.mshrs[line] = entry
        self.miss_completions[done_cycle].append(line)
        if inst.dst is not None:
            wave.pending_regs[inst.dst] = done_cycle

    def _issue(
        self,
        wave: WaveState,
    ) -> None:
        inst = wave.next_instruction

        if (
            self.last_issued_wave is not None
            and self.last_issued_wave != wave.wave_id
        ):
            self.scheduler_switches += 1

        self.last_issued_wave = wave.wave_id
        wave.last_issue_cycle = self.cycle
        wave.pc += 1
        wave.issued_instructions += 1
        self.issued_instructions += 1

        if inst.kind == "alu":
            if inst.dst is not None:
                self._schedule_reg_completion(
                    wave,
                    inst.dst,
                    self.cycle + max(1, inst.latency),
                )
            return

        if inst.kind == "mem":
            self._issue_memory(wave, inst)
            return

        if inst.kind == "halt":
            if wave.pending_regs:
                raise AssertionError(
                    "HALT issued while register results remain pending"
                )
            wave.halted = True
            wave.completion_cycle = self.cycle
            return

        raise ValueError(f"unsupported instruction kind: {inst.kind}")

    def run(
        self,
        max_cycles: int = 1_000_000,
    ) -> MLPResult:
        while not all(wave.halted for wave in self.waves):
            if self.cycle >= max_cycles:
                raise RuntimeError(
                    "SIM16 non-blocking memory model timed out"
                )

            self._complete_cycle()

            ready: list[WaveState] = []
            reasons: list[str] = []

            for wave in self.waves:
                ok, reason = self._ready_reason(wave)
                if ok:
                    ready.append(wave)
                elif not wave.halted and reason is not None:
                    reasons.append(reason)
                    if reason == "mshr":
                        self.mshr_full_wave_cycles += 1
                    elif reason == "dependency":
                        self.dependency_wave_cycles += 1

            if ready:
                self._issue(self._choose_wave(ready))
            else:
                if any(reason == "mshr" for reason in reasons):
                    self.mshr_full_global_cycles += 1

            occupancy = len(self.mshrs)
            self.mshr_occupancy_sum += occupancy
            self.peak_mshr_occupancy = max(
                self.peak_mshr_occupancy,
                occupancy,
            )

            self.cycle += 1

        completions = sorted(
            int(wave.completion_cycle)
            for wave in self.waves
            if wave.completion_cycle is not None
        )
        p95_index = max(
            0,
            ceil(0.95 * len(completions)) - 1,
        )

        return MLPResult(
            cycles=self.cycle,
            issued_instructions=self.issued_instructions,
            memory_instructions=self.memory_instructions,
            ipc=self.issued_instructions / self.cycle,
            dram_misses=self.dram_misses,
            l2_hits=self.l2_hits,
            mshr_merges=self.mshr_merges,
            mshr_full_global_cycles=self.mshr_full_global_cycles,
            mshr_full_wave_cycles=self.mshr_full_wave_cycles,
            dependency_wave_cycles=self.dependency_wave_cycles,
            average_mshr_occupancy=(
                self.mshr_occupancy_sum / self.cycle
            ),
            peak_mshr_occupancy=self.peak_mshr_occupancy,
            scheduler_switches=self.scheduler_switches,
            p95_wave_completion=completions[p95_index],
            instruction_signature=tuple(
                wave.issued_instructions
                for wave in self.waves
            ),
            memory_signature=tuple(
                wave.memory_instructions
                for wave in self.waves
            ),
            adaptive_merge_choices=self.adaptive_merge_choices,
            adaptive_locality_choices=self.adaptive_locality_choices,
            adaptive_fallback_choices=self.adaptive_fallback_choices,
        )


WORKLOADS = (
    "independent_mlp",
    "dependent_chain",
    "mixed_overlap",
    "shared_locality",
    "thrash_locality",
)


def build_program(
    workload: str,
    wave_id: int,
    *,
    memory_ops: int = 8,
    locality_group: int = 4,
) -> list[Instruction]:
    program: list[Instruction] = []

    if workload == "independent_mlp":
        for index in range(memory_ops):
            program.append(
                Instruction.load(
                    dst=8 + index,
                    line=wave_id * 100 + index,
                )
            )
        for index in range(memory_ops):
            program.append(
                Instruction.alu(
                    dst=24 + index,
                    srcs=(8 + index,),
                    latency=2,
                )
            )

    elif workload == "dependent_chain":
        for index in range(memory_ops):
            source = 8 + (index % 8)
            program.append(
                Instruction.load(
                    dst=source,
                    line=wave_id * 100 + index,
                )
            )
            program.append(
                Instruction.alu(
                    dst=24 + (index % 8),
                    srcs=(source,),
                    latency=2,
                )
            )

    elif workload == "mixed_overlap":
        for index in range(memory_ops):
            source = 8 + (index % 8)
            program.append(
                Instruction.load(
                    dst=source,
                    line=wave_id * 100 + index,
                )
            )
            program.append(
                Instruction.alu(
                    dst=40 + (index % 8),
                    srcs=(),
                    latency=2,
                )
            )
            if index % 2 == 1:
                program.append(
                    Instruction.alu(
                        dst=24 + (index % 8),
                        srcs=(source,),
                        latency=2,
                    )
                )

    elif workload == "shared_locality":
        for index in range(memory_ops * 2):
            source = 8 + (index % 8)
            program.append(
                Instruction.load(
                    dst=source,
                    line=index % locality_group,
                )
            )
            if index % locality_group == locality_group - 1:
                program.append(
                    Instruction.alu(
                        dst=24 + (index % 8),
                        srcs=(source,),
                        latency=2,
                    )
                )

    elif workload == "thrash_locality":
        base = wave_id * locality_group
        for epoch in range(4):
            for offset in range(locality_group):
                index = epoch * locality_group + offset
                source = 8 + (index % 8)
                program.append(
                    Instruction.load(
                        dst=source,
                        line=base + offset,
                    )
                )
                if offset == locality_group - 1:
                    program.append(
                        Instruction.alu(
                            dst=24 + (epoch % 8),
                            srcs=(source,),
                            latency=2,
                        )
                    )

    else:
        raise ValueError(f"unknown SIM16 workload: {workload}")

    program.append(Instruction.halt())
    return program


def run_workload(
    workload: str,
    wave_count: int,
    mshr_capacity: int,
    scheduler_policy: str,
    *,
    l2_capacity_lines: int = 8,
    dram_latency: int = 40,
    l2_hit_latency: int = 6,
) -> MLPResult:
    if wave_count <= 0:
        raise ValueError("wave_count must be positive")

    programs = [
        build_program(workload, wave_id)
        for wave_id in range(wave_count)
    ]
    return NonBlockingMemoryStudy(
        programs,
        MLPConfig(
            mshr_capacity=mshr_capacity,
            l2_capacity_lines=l2_capacity_lines,
            dram_latency=dram_latency,
            l2_hit_latency=l2_hit_latency,
            scheduler_policy=scheduler_policy,
        ),
    ).run()
