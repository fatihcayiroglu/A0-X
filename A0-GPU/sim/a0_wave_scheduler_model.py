#!/usr/bin/env python3
"""A0-RTL7A reference model for the resident-wave LRR scheduler."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SchedulerObservation:
    grant_valid: int
    grant_wave: int
    lrr_valid: int
    lrr_wave: int
    override_accepted: int
    pressure_high: int
    ready_count: int
    memory_ready_count: int
    non_memory_ready_count: int
    memory_stalled_count: int
    merge_ready_count: int
    rr_cursor: int


class A0WaveSchedulerModel:
    def __init__(self, resident_waves: int = 4):
        if resident_waves <= 0:
            raise ValueError("resident_waves must be positive")
        self.resident_waves = resident_waves
        self.cursor = 0

    def _mask_limit(self) -> int:
        return (1 << self.resident_waves) - 1

    def _count(self, mask: int) -> int:
        return (mask & self._mask_limit()).bit_count()

    def _lrr(self, ready_mask: int) -> tuple[int, int]:
        ready_mask &= self._mask_limit()
        for offset in range(self.resident_waves):
            wave = (self.cursor + offset) % self.resident_waves
            if ready_mask & (1 << wave):
                return 1, wave
        return 0, 0

    def observe(
        self,
        *,
        ready_mask: int,
        memory_ready_mask: int,
        non_memory_ready_mask: int,
        memory_stalled_mask: int,
        merge_ready_mask: int,
        mshr_occupancy: int,
        mshr_capacity: int,
        override_valid: int,
        override_wave: int,
    ) -> SchedulerObservation:
        limit = self._mask_limit()
        ready_mask &= limit
        memory_ready_mask &= limit
        non_memory_ready_mask &= limit
        memory_stalled_mask &= limit
        merge_ready_mask &= limit

        lrr_valid, lrr_wave = self._lrr(ready_mask)

        override_accepted = int(
            bool(override_valid)
            and 0 <= override_wave < self.resident_waves
            and bool(ready_mask & (1 << override_wave))
        )

        if override_accepted:
            grant_valid = 1
            grant_wave = override_wave
        else:
            grant_valid = lrr_valid
            grant_wave = lrr_wave

        pressure_high = int(
            mshr_capacity != 0
            and (2 * mshr_occupancy) >= mshr_capacity
        )

        merge_visible = (
            merge_ready_mask
            & ready_mask
            & memory_ready_mask
        )

        return SchedulerObservation(
            grant_valid=grant_valid,
            grant_wave=grant_wave,
            lrr_valid=lrr_valid,
            lrr_wave=lrr_wave,
            override_accepted=override_accepted,
            pressure_high=pressure_high,
            ready_count=self._count(ready_mask),
            memory_ready_count=self._count(
                memory_ready_mask & ready_mask
            ),
            non_memory_ready_count=self._count(
                non_memory_ready_mask & ready_mask
            ),
            memory_stalled_count=self._count(
                memory_stalled_mask
            ),
            merge_ready_count=self._count(merge_visible),
            rr_cursor=self.cursor,
        )

    def step(
        self,
        observation: SchedulerObservation,
        *,
        grant_fire: int,
    ) -> None:
        if grant_fire and observation.grant_valid:
            self.cursor = (
                observation.grant_wave + 1
            ) % self.resident_waves
