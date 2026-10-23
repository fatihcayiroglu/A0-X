#!/usr/bin/env python3

from dataclasses import dataclass
from typing import Optional

from a0_isa import Instruction, Opcode
from a0_sim import timing_destinations, timing_sources


@dataclass(frozen=True)
class QueueDependencyContract:
    vector_src0_enable: bool
    vector_src1_enable: bool
    vector_src2_enable: bool
    vector_dst_enable: bool
    predicate_src_enable: bool
    predicate_dst_enable: bool


@dataclass(frozen=True)
class QueuePayload:
    pc: int
    instruction: Instruction
    deps: QueueDependencyContract


@dataclass
class _Entry:
    payload: QueuePayload
    age: int


def classifier_contract(instr: Instruction) -> QueueDependencyContract:
    """Python mirror of the current RTL dependency-classifier contract.

    Readiness correctness is *not* derived from this function in the golden
    model; readiness uses timing_sources()/timing_destinations().  Keeping the
    stimulus-side classifier mapping separate makes the differential test able
    to catch a bad enable contract.
    """

    vector_binary = {
        Opcode.VADD,
        Opcode.VSUB,
        Opcode.VMUL,
        Opcode.VAND,
        Opcode.VOR,
        Opcode.VXOR,
    }

    if instr.opcode in vector_binary:
        return QueueDependencyContract(
            True,
            True,
            False,
            True,
            bool(instr.flags & 0x1),
            False,
        )

    if instr.opcode in {
        Opcode.VCMP_EQ,
        Opcode.VCMP_LT,
        Opcode.VCMP_LE,
    }:
        return QueueDependencyContract(
            True,
            True,
            False,
            False,
            False,
            True,
        )

    if instr.opcode == Opcode.VLOADX:
        return QueueDependencyContract(
            False,
            True,
            False,
            True,
            bool(instr.flags & 0x1),
            False,
        )

    if instr.opcode == Opcode.VSTOREX:
        return QueueDependencyContract(
            False,
            True,
            True,
            False,
            bool(instr.flags & 0x1),
            False,
        )

    if instr.opcode == Opcode.SPLIT:
        return QueueDependencyContract(
            False,
            False,
            False,
            False,
            True,
            False,
        )

    return QueueDependencyContract(
        False,
        False,
        False,
        False,
        False,
        False,
    )


class A0QueueModel:
    """Golden behavioral model for the standalone RTL5E issue queue.

    The model intentionally tracks only the vector and vector-predicate
    dependency classes owned by the current RTL5B/RTL5E contract. Scalar S/Q
    dependencies remain outside this queue milestone.
    """

    def __init__(self, depth: int = 8):
        if depth <= 0:
            raise ValueError("depth must be positive")
        self.depth = depth
        self.entries: list[Optional[_Entry]] = [None] * depth

    def reset(self) -> None:
        self.entries = [None] * self.depth

    @property
    def count(self) -> int:
        return sum(entry is not None for entry in self.entries)

    def _entry_ready(
        self,
        entry: _Entry,
        busy_vector: int,
        busy_predicate: int,
    ) -> bool:
        instr = entry.payload.instruction

        for register_class, index in timing_sources(instr):
            if register_class == "V":
                if (busy_vector >> index) & 1:
                    return False
            elif register_class == "P":
                if (busy_predicate >> index) & 1:
                    return False

        for register_class, index in timing_destinations(instr):
            if register_class == "V":
                if (busy_vector >> index) & 1:
                    return False
            elif register_class == "P":
                if (busy_predicate >> index) & 1:
                    return False

        return True

    def peek(
        self,
        *,
        busy_vector: int,
        busy_predicate: int,
    ) -> tuple[Optional[int], Optional[QueuePayload]]:
        candidates = [
            (index, entry)
            for index, entry in enumerate(self.entries)
            if entry is not None
            and self._entry_ready(entry, busy_vector, busy_predicate)
        ]

        if not candidates:
            return None, None

        index, entry = min(candidates, key=lambda item: item[1].age)
        return index, entry.payload

    def combinational(
        self,
        *,
        issue_ready: bool,
        busy_vector: int,
        busy_predicate: int,
    ) -> dict:
        issue_index, payload = self.peek(
            busy_vector=busy_vector,
            busy_predicate=busy_predicate,
        )
        issue_valid = payload is not None
        issue_fire = issue_valid and issue_ready
        free_index = next(
            (
                index
                for index, entry in enumerate(self.entries)
                if entry is None
            ),
            None,
        )
        dispatch_ready = free_index is not None or issue_fire

        return {
            "dispatch_ready": dispatch_ready,
            "issue_valid": issue_valid,
            "issue_index": issue_index,
            "issue_payload": payload,
            "issue_fire": issue_fire,
            "free_index": free_index,
        }

    def step(
        self,
        *,
        dispatch_payload: Optional[QueuePayload],
        issue_ready: bool,
        busy_vector: int,
        busy_predicate: int,
    ) -> dict:
        comb = self.combinational(
            issue_ready=issue_ready,
            busy_vector=busy_vector,
            busy_predicate=busy_predicate,
        )

        dispatch_fire = (
            dispatch_payload is not None
            and comb["dispatch_ready"]
        )

        issue_index = comb["issue_index"]
        issue_fire = comb["issue_fire"]
        issued_age = None

        if issue_fire:
            assert issue_index is not None
            issued_entry = self.entries[issue_index]
            assert issued_entry is not None
            issued_age = issued_entry.age

            for index, entry in enumerate(self.entries):
                if (
                    entry is not None
                    and index != issue_index
                    and entry.age > issued_age
                ):
                    entry.age -= 1

            self.entries[issue_index] = None

        if dispatch_fire:
            if comb["free_index"] is not None:
                dispatch_index = comb["free_index"]
            else:
                assert issue_fire
                assert issue_index is not None
                dispatch_index = issue_index

            new_age = self.count
            self.entries[dispatch_index] = _Entry(
                payload=dispatch_payload,
                age=new_age,
            )

        ages = sorted(
            entry.age for entry in self.entries if entry is not None
        )
        if ages != list(range(len(ages))):
            raise AssertionError(f"non-compact queue ages: {ages}")

        return {
            **comb,
            "dispatch_fire": dispatch_fire,
        }
