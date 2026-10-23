#!/usr/bin/env python3
"""Cycle reference model for the A0-RTL8A MSHR table."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable


@dataclass
class Waiter:
    context: int
    dst: int
    lane_mask: int
    word_select: tuple[int, ...]


@dataclass
class Entry:
    valid: bool = False
    issued: bool = False
    response_ready: bool = False
    fault: bool = False
    line_addr: int = 0
    line_data: tuple[int, ...] = field(default_factory=tuple)
    waiters: dict[int, Waiter] = field(default_factory=dict)


@dataclass(frozen=True)
class Observation:
    req_ready: int
    req_fire: int
    req_allocated: int
    req_merged: int
    req_blocked_draining: int
    req_duplicate_waiter: int
    req_entry: int
    miss_valid: int
    miss_entry: int
    miss_line: int
    resp_accept: int
    resp_tag_error: int
    complete_valid: int
    complete_entry: int
    complete_wave: int
    complete_context: int
    complete_dst: int
    complete_lane_mask: int
    complete_word_select: tuple[int, ...]
    complete_fault: int
    complete_line_data: tuple[int, ...]
    occupancy: int
    full: int
    empty: int
    valid_mask: int
    issued_mask: int
    response_ready_mask: int


class A0MSHRModel:
    def __init__(
        self,
        *,
        mshr_count: int = 4,
        resident_waves: int = 3,
        wave_size: int = 4,
        line_words: int = 4,
    ) -> None:
        if mshr_count <= 0:
            raise ValueError("mshr_count must be positive")
        if resident_waves <= 0:
            raise ValueError("resident_waves must be positive")
        if wave_size <= 0:
            raise ValueError("wave_size must be positive")
        if line_words <= 0:
            raise ValueError("line_words must be positive")

        self.mshr_count = mshr_count
        self.resident_waves = resident_waves
        self.wave_size = wave_size
        self.line_words = line_words
        self.entries = [
            Entry(line_data=(0,) * line_words)
            for _ in range(mshr_count)
        ]

    def _masks(self) -> tuple[int, int, int, int]:
        valid = 0
        issued = 0
        response = 0
        occupancy = 0

        for index, entry in enumerate(self.entries):
            if entry.valid:
                valid |= 1 << index
                occupancy += 1
                if entry.issued:
                    issued |= 1 << index
                if entry.response_ready:
                    response |= 1 << index

        return valid, issued, response, occupancy

    def _lookup(self, line_addr: int) -> tuple[int | None, int | None, int | None]:
        open_match = None
        draining_match = None
        free = None

        for index, entry in enumerate(self.entries):
            if (
                open_match is None
                and entry.valid
                and not entry.response_ready
                and entry.line_addr == line_addr
            ):
                open_match = index

            if (
                draining_match is None
                and entry.valid
                and entry.response_ready
                and entry.line_addr == line_addr
            ):
                draining_match = index

            if free is None and not entry.valid:
                free = index

        return open_match, draining_match, free

    def _miss_candidate(self) -> int | None:
        for index, entry in enumerate(self.entries):
            if entry.valid and not entry.issued and not entry.response_ready:
                return index
        return None

    def _completion_candidate(self) -> tuple[int | None, int | None]:
        for entry_index, entry in enumerate(self.entries):
            if not entry.valid or not entry.response_ready:
                continue
            if not entry.waiters:
                continue
            return entry_index, min(entry.waiters)
        return None, None

    def observe(
        self,
        *,
        req_valid: int,
        req_line: int,
        req_wave: int,
        req_context: int,
        req_dst: int,
        req_lane_mask: int,
        req_word_select: Iterable[int],
        miss_ready: int,
        resp_valid: int,
        resp_entry: int,
        resp_line: int,
        resp_fault: int,
        resp_line_data: Iterable[int],
        complete_ready: int,
    ) -> Observation:
        del req_context, req_dst, req_word_select, resp_fault, resp_line_data, complete_ready

        valid_mask, issued_mask, response_mask, occupancy = self._masks()
        open_match, draining_match, free = self._lookup(req_line)

        wave_valid = 0 <= req_wave < self.resident_waves
        duplicate = bool(
            open_match is not None
            and wave_valid
            and req_wave in self.entries[open_match].waiters
        )

        req_ready = int(
            wave_valid
            and req_lane_mask != 0
            and draining_match is None
            and (
                (open_match is not None and not duplicate)
                or (open_match is None and free is not None)
            )
        )
        req_fire = int(bool(req_valid) and bool(req_ready))
        req_merged = int(bool(req_fire) and open_match is not None)
        req_allocated = int(bool(req_fire) and open_match is None)
        req_entry = (
            open_match
            if open_match is not None
            else (free if free is not None else 0)
        )

        miss_entry = self._miss_candidate()
        miss_valid = int(miss_entry is not None)
        miss_line = (
            self.entries[miss_entry].line_addr
            if miss_entry is not None
            else 0
        )
        miss_entry_value = miss_entry if miss_entry is not None else 0

        response_entry_valid = 0 <= resp_entry < self.mshr_count
        response_live = (
            response_entry_valid
            and self.entries[resp_entry].valid
        )
        same_cycle_issue = bool(
            miss_valid
            and miss_ready
            and miss_entry_value == resp_entry
        )
        response_tag_match = bool(
            response_live
            and (
                self.entries[resp_entry].issued
                or same_cycle_issue
            )
            and not self.entries[resp_entry].response_ready
            and self.entries[resp_entry].line_addr == resp_line
        )
        resp_accept = int(bool(resp_valid) and response_tag_match)
        resp_tag_error = int(bool(resp_valid) and not response_tag_match)

        complete_entry, complete_wave = self._completion_candidate()
        complete_valid = int(complete_entry is not None and complete_wave is not None)

        if complete_valid:
            entry = self.entries[complete_entry]
            waiter = entry.waiters[complete_wave]
            complete_context = waiter.context
            complete_dst = waiter.dst
            complete_lane_mask = waiter.lane_mask
            complete_word_select = waiter.word_select
            complete_fault = int(entry.fault)
            complete_line_data = entry.line_data
            complete_entry_value = complete_entry
            complete_wave_value = complete_wave
        else:
            complete_context = 0
            complete_dst = 0
            complete_lane_mask = 0
            complete_word_select = (0,) * self.wave_size
            complete_fault = 0
            complete_line_data = (0,) * self.line_words
            complete_entry_value = 0
            complete_wave_value = 0

        return Observation(
            req_ready=req_ready,
            req_fire=req_fire,
            req_allocated=req_allocated,
            req_merged=req_merged,
            req_blocked_draining=int(bool(req_valid) and draining_match is not None),
            req_duplicate_waiter=int(bool(req_valid) and open_match is not None and duplicate),
            req_entry=req_entry,
            miss_valid=miss_valid,
            miss_entry=miss_entry_value,
            miss_line=miss_line,
            resp_accept=resp_accept,
            resp_tag_error=resp_tag_error,
            complete_valid=complete_valid,
            complete_entry=complete_entry_value,
            complete_wave=complete_wave_value,
            complete_context=complete_context,
            complete_dst=complete_dst,
            complete_lane_mask=complete_lane_mask,
            complete_word_select=tuple(complete_word_select),
            complete_fault=complete_fault,
            complete_line_data=tuple(complete_line_data),
            occupancy=occupancy,
            full=int(occupancy == self.mshr_count),
            empty=int(occupancy == 0),
            valid_mask=valid_mask,
            issued_mask=issued_mask,
            response_ready_mask=response_mask,
        )

    def step(
        self,
        observation: Observation,
        *,
        req_valid: int,
        req_line: int,
        req_wave: int,
        req_context: int,
        req_dst: int,
        req_lane_mask: int,
        req_word_select: Iterable[int],
        miss_ready: int,
        resp_valid: int,
        resp_entry: int,
        resp_line: int,
        resp_fault: int,
        resp_line_data: Iterable[int],
        complete_ready: int,
    ) -> None:
        del req_valid, resp_valid

        # Determine old-state completion cardinality before mutating anything.
        completion_last = False
        if observation.complete_valid:
            old_entry = self.entries[observation.complete_entry]
            completion_last = len(old_entry.waiters) == 1

        if observation.req_fire:
            entry = self.entries[observation.req_entry]
            if observation.req_allocated:
                entry.valid = True
                entry.issued = False
                entry.response_ready = False
                entry.fault = False
                entry.line_addr = req_line
                entry.line_data = (0,) * self.line_words

            entry.waiters[req_wave] = Waiter(
                context=req_context,
                dst=req_dst,
                lane_mask=req_lane_mask,
                word_select=tuple(req_word_select),
            )

        if observation.miss_valid and miss_ready:
            self.entries[observation.miss_entry].issued = True

        if observation.resp_accept:
            entry = self.entries[resp_entry]
            entry.response_ready = True
            entry.fault = bool(resp_fault)
            entry.line_data = tuple(resp_line_data)

        if observation.complete_valid and complete_ready:
            entry = self.entries[observation.complete_entry]
            entry.waiters.pop(observation.complete_wave, None)
            if completion_last:
                entry.valid = False
                entry.issued = False
                entry.response_ready = False
                entry.fault = False
                entry.waiters.clear()

    def assert_invariants(self) -> None:
        live_lines: set[int] = set()
        for index, entry in enumerate(self.entries):
            if not entry.valid:
                if entry.waiters:
                    raise AssertionError(
                        f"invalid entry {index} retains waiters"
                    )
                continue

            if entry.line_addr in live_lines:
                raise AssertionError(
                    f"duplicate live line tag {entry.line_addr}"
                )
            live_lines.add(entry.line_addr)

            if not entry.waiters:
                raise AssertionError(
                    f"live entry {index} has no waiters"
                )

            if entry.response_ready and not entry.issued:
                raise AssertionError(
                    f"response-ready entry {index} was never issued"
                )

            for wave, waiter in entry.waiters.items():
                if not 0 <= wave < self.resident_waves:
                    raise AssertionError(
                        f"invalid waiter wave {wave} in entry {index}"
                    )
                if len(waiter.word_select) != self.wave_size:
                    raise AssertionError(
                        f"waiter selector width mismatch entry={index} wave={wave}"
                    )

            if len(entry.line_data) != self.line_words:
                raise AssertionError(
                    f"line-data width mismatch entry={index}"
                )

    def cycle(self, **kwargs) -> Observation:
        observation = self.observe(**kwargs)
        self.step(observation, **kwargs)
        self.assert_invariants()
        return observation
