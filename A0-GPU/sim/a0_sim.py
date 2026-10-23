import struct
import math
from a0_asm import FLAG_PREDICATED, assemble_source
from a0_isa import Opcode, decode


WAVE_SIZE = 32
VECTOR_REG_COUNT = 64
SCALAR_REG_COUNT = 32
SCALAR_PREDICATE_REG_COUNT = 16
PREDICATE_REG_COUNT = 16
MEMORY_WORDS = 1024
MEMORY_WORD_BYTES = 4
MEMORY_TRANSACTION_WORDS = 8
MEMORY_TRANSACTION_BYTES = (
    MEMORY_WORD_BYTES * MEMORY_TRANSACTION_WORDS
)
SHARED_MEMORY_WORDS = 256

UINT32_MASK = 0xFFFFFFFF


def u32(value: int) -> int:
    return value & UINT32_MASK


def f32_from_bits(bits: int) -> float:
    return struct.unpack(
        ">f",
        struct.pack(
            ">I",
            bits & 0xFFFFFFFF,
        ),
    )[0]


def f32_to_bits(value: float) -> int:
    try:
        packed = struct.pack(
            ">f",
            float(value),
        )
    except OverflowError:
        packed = struct.pack(
            ">f",
            math.copysign(
                math.inf,
                value,
            ),
        )

    return struct.unpack(
        ">I",
        packed,
    )[0]


def f32_add_bits(
    a_bits: int,
    b_bits: int,
) -> int:
    return f32_to_bits(
        f32_from_bits(a_bits)
        + f32_from_bits(b_bits)
    )


def f32_sub_bits(
    a_bits: int,
    b_bits: int,
) -> int:
    return f32_to_bits(
        f32_from_bits(a_bits)
        - f32_from_bits(b_bits)
    )


def f32_mul_bits(
    a_bits: int,
    b_bits: int,
) -> int:
    return f32_to_bits(
        f32_from_bits(a_bits)
        * f32_from_bits(b_bits)
    )


def f32_fma_bits(
    a_bits: int,
    b_bits: int,
    c_bits: int,
) -> int:
    if not hasattr(math, "fma"):
        raise RuntimeError(
            "Host Python does not provide math.fma"
        )

    return f32_to_bits(
        math.fma(
            f32_from_bits(a_bits),
            f32_from_bits(b_bits),
            f32_from_bits(c_bits),
        )
    )


def sign_extend_24(value: int) -> int:
    value &= 0xFFFFFF

    if value & 0x800000:
        return value - 0x1000000

    return value


def coalesce_word_addresses(
    addresses,
    transaction_words=MEMORY_TRANSACTION_WORDS,
):
    addresses = list(addresses)

    if transaction_words <= 0:
        raise ValueError(
            "transaction_words must be positive"
        )

    if any(address < 0 for address in addresses):
        raise ValueError(
            "coalescer received negative word address"
        )

    lane_requests = len(addresses)

    unique_addresses = sorted(
        set(addresses)
    )

    segments = sorted(
        {
            address // transaction_words
            for address in unique_addresses
        }
    )

    unique_words = len(unique_addresses)
    transactions = len(segments)

    useful_bytes = (
        unique_words * MEMORY_WORD_BYTES
    )

    transferred_bytes = (
        transactions
        * transaction_words
        * MEMORY_WORD_BYTES
    )

    if transferred_bytes:
        coalescing_efficiency = (
            useful_bytes / transferred_bytes
        )
    else:
        coalescing_efficiency = 0.0

    if unique_words:
        broadcast_factor = (
            lane_requests / unique_words
        )
    else:
        broadcast_factor = 0.0

    return {
        "lane_requests": lane_requests,
        "unique_words": unique_words,
        "transactions": transactions,
        "useful_bytes": useful_bytes,
        "transferred_bytes": transferred_bytes,
        "coalescing_efficiency": coalescing_efficiency,
        "broadcast_factor": broadcast_factor,
        "word_addresses": unique_addresses,
        "segment_ids": segments,
        "segment_base_words": [
            segment * transaction_words
            for segment in segments
        ],
    }


class WorkgroupState:
    def __init__(
        self,
        shared_words=SHARED_MEMORY_WORDS,
    ):
        if shared_words <= 0:
            raise ValueError(
                "shared_words must be positive"
            )

        self.shared_words = shared_words

        self.shared_memory = [
            0
            for _ in range(shared_words)
        ]


class A0GPU:
    def __init__(
        self,
        workgroup=None,
        wave_id=0,
    ):
        if wave_id < 0:
            raise ValueError(
                "wave_id must be non-negative"
            )

        if workgroup is None:
            workgroup = WorkgroupState()

        self.workgroup = workgroup
        self.wave_id = wave_id

        self.waiting_at_barrier = False
        self.barrier_epoch = 0

        self.pc = 0
        self.halted = False

        self.exec_mask = [True] * WAVE_SIZE

        self.reconvergence_stack = []

        self.predicate_regs = [
            [False for _ in range(WAVE_SIZE)]
            for _ in range(PREDICATE_REG_COUNT)
        ]

        self.vector_regs = [
            [0 for _ in range(WAVE_SIZE)]
            for _ in range(VECTOR_REG_COUNT)
        ]

        self.scalar_regs = [
            0 for _ in range(SCALAR_REG_COUNT)
        ]

        self.scalar_predicate_regs = [
            False
            for _ in range(SCALAR_PREDICATE_REG_COUNT)
        ]

        self.memory = [
            0 for _ in range(MEMORY_WORDS)
        ]

        self.memory_trace = []

        self.program_words = []

    def load_program(self, machine_code):
        self.program_words = list(machine_code)
        self.pc = 0
        self.halted = False

    def thread_enabled(self, instr, thread):
        if not self.exec_mask[thread]:
            return False

        if instr.flags & FLAG_PREDICATED:
            return self.predicate_regs[instr.pred][thread]

        return True

    def record_memory_access(
        self,
        opcode_name,
        addresses,
    ):
        metrics = coalesce_word_addresses(
            addresses
        )

        metrics["opcode"] = opcode_name

        self.memory_trace.append(metrics)

        return metrics

    def memory_summary(self):
        lane_requests = sum(
            entry["lane_requests"]
            for entry in self.memory_trace
        )

        unique_words = sum(
            entry["unique_words"]
            for entry in self.memory_trace
        )

        transactions = sum(
            entry["transactions"]
            for entry in self.memory_trace
        )

        useful_bytes = sum(
            entry["useful_bytes"]
            for entry in self.memory_trace
        )

        transferred_bytes = sum(
            entry["transferred_bytes"]
            for entry in self.memory_trace
        )

        if transferred_bytes:
            efficiency = (
                useful_bytes / transferred_bytes
            )
        else:
            efficiency = 0.0

        return {
            "operations": len(self.memory_trace),
            "lane_requests": lane_requests,
            "unique_words": unique_words,
            "transactions": transactions,
            "useful_bytes": useful_bytes,
            "transferred_bytes": transferred_bytes,
            "coalescing_efficiency": efficiency,
        }

    def execute_split(self, instr):
        parent_mask = list(self.exec_mask)
        predicate_mask = self.predicate_regs[instr.pred]

        then_mask = [
            parent_mask[thread] and predicate_mask[thread]
            for thread in range(WAVE_SIZE)
        ]

        else_mask = [
            parent_mask[thread] and not predicate_mask[thread]
            for thread in range(WAVE_SIZE)
        ]

        self.reconvergence_stack.append(
            {
                "parent_mask": parent_mask,
                "else_mask": else_mask,
                "else_entered": False,
            }
        )

        self.exec_mask = then_mask

    def execute_else(self):
        if not self.reconvergence_stack:
            raise RuntimeError("ELSE without matching SPLIT")

        frame = self.reconvergence_stack[-1]

        if frame["else_entered"]:
            raise RuntimeError("Duplicate ELSE for SPLIT")

        frame["else_entered"] = True
        self.exec_mask = list(frame["else_mask"])

    def execute_join(self):
        if not self.reconvergence_stack:
            raise RuntimeError("JOIN without matching SPLIT")

        frame = self.reconvergence_stack.pop()
        self.exec_mask = list(frame["parent_mask"])

    def execute_instruction(self, instr):
        if instr.opcode == Opcode.NOP:
            return

        if instr.opcode in {
            Opcode.VCMP_EQ,
            Opcode.VCMP_LT,
            Opcode.VCMP_LE,
        }:
            for thread in range(WAVE_SIZE):
                if not self.exec_mask[thread]:
                    continue

                a = self.vector_regs[
                    instr.src0
                ][thread]

                b = self.vector_regs[
                    instr.src1
                ][thread]

                if instr.opcode == Opcode.VCMP_EQ:
                    result = a == b

                elif instr.opcode == Opcode.VCMP_LT:
                    result = a < b

                else:
                    result = a <= b

                self.predicate_regs[
                    instr.pred
                ][thread] = result

            return

        if instr.opcode == Opcode.VADD:
            for thread in range(WAVE_SIZE):
                if self.thread_enabled(instr, thread):
                    self.vector_regs[instr.dst][thread] = u32(
                        self.vector_regs[instr.src0][thread]
                        + self.vector_regs[instr.src1][thread]
                    )

            return

        if instr.opcode == Opcode.VSUB:
            for thread in range(WAVE_SIZE):
                if self.thread_enabled(instr, thread):
                    self.vector_regs[instr.dst][thread] = u32(
                        self.vector_regs[instr.src0][thread]
                        - self.vector_regs[instr.src1][thread]
                    )

            return

        if instr.opcode == Opcode.VMUL:
            for thread in range(WAVE_SIZE):
                if self.thread_enabled(instr, thread):
                    self.vector_regs[instr.dst][thread] = u32(
                        self.vector_regs[instr.src0][thread]
                        * self.vector_regs[instr.src1][thread]
                    )

            return

        if instr.opcode == Opcode.LDSLOAD:
            immediate = sign_extend_24(
                instr.imm24
            )

            accesses = []

            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(
                    instr,
                    thread,
                ):
                    continue

                address = (
                    self.vector_regs[
                        instr.src0
                    ][thread]
                    + immediate
                )

                if not (
                    0
                    <= address
                    < self.workgroup.shared_words
                ):
                    raise RuntimeError(
                        f"LDSLOAD outside shared memory: "
                        f"wave={self.wave_id} "
                        f"lane={thread} "
                        f"address={address}"
                    )

                accesses.append(
                    (thread, address)
                )

            for thread, address in accesses:
                self.vector_regs[
                    instr.dst
                ][thread] = u32(
                    self.workgroup.shared_memory[
                        address
                    ]
                )

            return

        if instr.opcode == Opcode.LDSSTORE:
            immediate = sign_extend_24(
                instr.imm24
            )

            accesses = []

            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(
                    instr,
                    thread,
                ):
                    continue

                address = (
                    self.vector_regs[
                        instr.src0
                    ][thread]
                    + immediate
                )

                if not (
                    0
                    <= address
                    < self.workgroup.shared_words
                ):
                    raise RuntimeError(
                        f"LDSSTORE outside shared memory: "
                        f"wave={self.wave_id} "
                        f"lane={thread} "
                        f"address={address}"
                    )

                accesses.append(
                    (thread, address)
                )

            for thread, address in accesses:
                self.workgroup.shared_memory[
                    address
                ] = u32(
                    self.vector_regs[
                        instr.src1
                    ][thread]
                )

            return

        if instr.opcode == Opcode.VLOADX:
            immediate = sign_extend_24(instr.imm24)
            scalar_base = self.scalar_regs[instr.src0]

            accesses = []

            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(instr, thread):
                    continue

                address = (
                    scalar_base
                    + self.vector_regs[instr.src1][thread]
                    + immediate
                )

                if not 0 <= address < MEMORY_WORDS:
                    raise RuntimeError(
                        f"VLOADX outside memory: "
                        f"lane={thread} address={address}"
                    )

                accesses.append(
                    (thread, address)
                )

            self.record_memory_access(
                "VLOADX",
                [
                    address
                    for _, address in accesses
                ],
            )

            for thread, address in accesses:
                self.vector_regs[instr.dst][thread] = u32(
                    self.memory[address]
                )

            return

        if instr.opcode == Opcode.VSTOREX:
            immediate = sign_extend_24(instr.imm24)
            scalar_base = self.scalar_regs[instr.src0]

            accesses = []

            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(instr, thread):
                    continue

                address = (
                    scalar_base
                    + self.vector_regs[instr.src1][thread]
                    + immediate
                )

                if not 0 <= address < MEMORY_WORDS:
                    raise RuntimeError(
                        f"VSTOREX outside memory: "
                        f"lane={thread} address={address}"
                    )

                accesses.append(
                    (thread, address)
                )

            self.record_memory_access(
                "VSTOREX",
                [
                    address
                    for _, address in accesses
                ],
            )

            for thread, address in accesses:
                self.memory[address] = u32(
                    self.vector_regs[instr.src2][thread]
                )

            return

        if instr.opcode == Opcode.VLOAD:
            base = instr.imm24

            if base + WAVE_SIZE > MEMORY_WORDS:
                raise RuntimeError(
                    "VLOAD outside memory"
                )

            for thread in range(WAVE_SIZE):
                if self.thread_enabled(instr, thread):
                    self.vector_regs[instr.dst][thread] = u32(
                        self.memory[base + thread]
                    )

            return

        if instr.opcode == Opcode.SLOAD:
            address = instr.imm24

            if not 0 <= address < MEMORY_WORDS:
                raise RuntimeError(
                    "SLOAD outside memory"
                )

            self.scalar_regs[instr.dst] = u32(
                self.memory[address]
            )
            return

        if instr.opcode == Opcode.SSTORE:
            address = instr.imm24

            if not 0 <= address < MEMORY_WORDS:
                raise RuntimeError(
                    "SSTORE outside memory"
                )

            self.memory[address] = u32(
                self.scalar_regs[instr.src0]
            )
            return

        if instr.opcode == Opcode.VSTORE:
            base = instr.imm24

            if base + WAVE_SIZE > MEMORY_WORDS:
                raise RuntimeError("VSTORE outside memory")

            for thread in range(WAVE_SIZE):
                if self.thread_enabled(instr, thread):
                    self.memory[base + thread] = (
                        self.vector_regs[instr.src0][thread]
                    )

            return

        if instr.opcode in {
            Opcode.VAND,
            Opcode.VOR,
            Opcode.VXOR,
        }:
            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(
                    instr,
                    thread,
                ):
                    continue

                a = self.vector_regs[
                    instr.src0
                ][thread]

                b = self.vector_regs[
                    instr.src1
                ][thread]

                if instr.opcode == Opcode.VAND:
                    result = a & b

                elif instr.opcode == Opcode.VOR:
                    result = a | b

                else:
                    result = a ^ b

                self.vector_regs[
                    instr.dst
                ][thread] = (
                    result & 0xFFFFFFFF
                )

            return

        if instr.opcode in {
            Opcode.VFADD,
            Opcode.VFSUB,
            Opcode.VFMUL,
        }:
            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(
                    instr,
                    thread,
                ):
                    continue

                a_bits = self.vector_regs[
                    instr.src0
                ][thread]

                b_bits = self.vector_regs[
                    instr.src1
                ][thread]

                if instr.opcode == Opcode.VFADD:
                    result = f32_add_bits(
                        a_bits,
                        b_bits,
                    )

                elif instr.opcode == Opcode.VFSUB:
                    result = f32_sub_bits(
                        a_bits,
                        b_bits,
                    )

                else:
                    result = f32_mul_bits(
                        a_bits,
                        b_bits,
                    )

                self.vector_regs[
                    instr.dst
                ][thread] = result

            return

        if instr.opcode == Opcode.VFFMA:
            for thread in range(WAVE_SIZE):
                if not self.thread_enabled(
                    instr,
                    thread,
                ):
                    continue

                self.vector_regs[
                    instr.dst
                ][thread] = f32_fma_bits(
                    self.vector_regs[
                        instr.src0
                    ][thread],
                    self.vector_regs[
                        instr.src1
                    ][thread],
                    self.vector_regs[
                        instr.src2
                    ][thread],
                )

            return

        if instr.opcode == Opcode.SADD:
            self.scalar_regs[instr.dst] = u32(
                self.scalar_regs[instr.src0]
                + self.scalar_regs[instr.src1]
            )
            return

        if instr.opcode == Opcode.SSUB:
            self.scalar_regs[instr.dst] = u32(
                self.scalar_regs[instr.src0]
                - self.scalar_regs[instr.src1]
            )
            return

        if instr.opcode == Opcode.SCMP_LT:
            self.scalar_predicate_regs[instr.pred] = (
                self.scalar_regs[instr.src0]
                < self.scalar_regs[instr.src1]
            )
            return

        if instr.opcode == Opcode.BRA:
            condition = (
                self.scalar_predicate_regs[instr.pred]
            )

            if not condition:
                return

            offset = sign_extend_24(instr.imm24)
            target_pc = self.pc + offset

            if not 0 <= target_pc < len(self.program_words):
                raise RuntimeError(
                    f"BRA target outside instruction memory: "
                    f"{target_pc}"
                )

            self.pc = target_pc
            return

        if instr.opcode == Opcode.BARRIER:
            if not all(self.exec_mask):
                raise RuntimeError(
                    "BARRIER requires full EXEC_MASK"
                )

            if self.reconvergence_stack:
                raise RuntimeError(
                    "BARRIER encountered with unresolved divergence"
                )

            self.waiting_at_barrier = True
            return

        if instr.opcode == Opcode.JMP:
            offset = sign_extend_24(instr.imm24)
            target_pc = self.pc + offset

            if not 0 <= target_pc < len(self.program_words):
                raise RuntimeError(
                    f"JMP target outside instruction memory: "
                    f"{target_pc}"
                )

            self.pc = target_pc
            return

        if instr.opcode == Opcode.SPLIT:
            self.execute_split(instr)
            return

        if instr.opcode == Opcode.ELSE:
            self.execute_else()
            return

        if instr.opcode == Opcode.JOIN:
            self.execute_join()
            return

        if instr.opcode == Opcode.HALT:
            self.halted = True
            return

        raise RuntimeError(
            f"Unsupported opcode: {instr.opcode.name}"
        )

    def step(self):
        if self.waiting_at_barrier:
            raise RuntimeError(
                "Wave is waiting at BARRIER; "
                "use WorkgroupScheduler"
            )
        if self.halted:
            return

        if self.pc >= len(self.program_words):
            raise RuntimeError(
                "Program counter outside instruction memory"
            )

        machine_word = self.program_words[self.pc]

        instr = decode(machine_word)

        current_pc = self.pc
        self.pc += 1

        print(
            f"PC={current_pc:04d} "
            f"WORD=0x{machine_word:016X} "
            f"OP={instr.opcode.name} "
            f"EXEC={mask_string(self.exec_mask)}"
        )

        self.execute_instruction(instr)

    def run(self, max_steps=100000):
        steps = 0

        while not self.halted:
            if steps >= max_steps:
                raise RuntimeError(
                    f"Maximum instruction count exceeded: "
                    f"{max_steps}"
                )

            self.step()
            steps += 1


class WorkgroupScheduler:
    def __init__(self, waves):
        self.waves = list(waves)

        if not self.waves:
            raise ValueError(
                "WorkgroupScheduler requires at least one wave"
            )

        workgroup = self.waves[0].workgroup

        for wave in self.waves:
            if wave.workgroup is not workgroup:
                raise ValueError(
                    "All scheduled waves must share one WorkgroupState"
                )

        wave_ids = [
            wave.wave_id
            for wave in self.waves
        ]

        if len(set(wave_ids)) != len(wave_ids):
            raise ValueError(
                "Scheduled waves require unique wave_id values"
            )

        self.workgroup = workgroup
        self.barrier_epoch = 0
        self.barrier_releases = 0
        self.total_wave_steps = 0

    def release_barrier_if_complete(self):
        waiting = [
            wave
            for wave in self.waves
            if wave.waiting_at_barrier
        ]

        if not waiting:
            return False

        halted = [
            wave
            for wave in self.waves
            if wave.halted
        ]

        if halted:
            waiting_ids = [
                wave.wave_id
                for wave in waiting
            ]

            halted_ids = [
                wave.wave_id
                for wave in halted
            ]

            raise RuntimeError(
                "Barrier deadlock: "
                f"waiting_waves={waiting_ids} "
                f"halted_waves={halted_ids}"
            )

        if len(waiting) != len(self.waves):
            return False

        self.barrier_epoch += 1
        self.barrier_releases += 1

        for wave in self.waves:
            wave.waiting_at_barrier = False
            wave.barrier_epoch = self.barrier_epoch

        return True

    def run(self, max_steps=100000):
        while True:
            if all(
                wave.halted
                for wave in self.waves
            ):
                return

            self.release_barrier_if_complete()

            progress = False

            for wave in self.waves:
                if wave.halted:
                    continue

                if wave.waiting_at_barrier:
                    continue

                if self.total_wave_steps >= max_steps:
                    raise RuntimeError(
                        "Maximum workgroup instruction "
                        f"count exceeded: {max_steps}"
                    )

                wave.step()

                self.total_wave_steps += 1
                progress = True

                self.release_barrier_if_complete()

            if all(
                wave.halted
                for wave in self.waves
            ):
                return

            if not progress:
                waiting_ids = [
                    wave.wave_id
                    for wave in self.waves
                    if wave.waiting_at_barrier
                ]

                halted_ids = [
                    wave.wave_id
                    for wave in self.waves
                    if wave.halted
                ]

                raise RuntimeError(
                    "Workgroup scheduler deadlock: "
                    f"waiting_waves={waiting_ids} "
                    f"halted_waves={halted_ids}"
                )




class OccupancyConfig:
    def __init__(
        self,
        *,
        vector_register_words=65536,
        scalar_registers=2048,
        shared_memory_words=16384,
        max_resident_waves=8,
        max_resident_workgroups=8,
    ):
        values = {
            "vector_register_words":
                vector_register_words,
            "scalar_registers":
                scalar_registers,
            "shared_memory_words":
                shared_memory_words,
            "max_resident_waves":
                max_resident_waves,
            "max_resident_workgroups":
                max_resident_workgroups,
        }

        for name, value in values.items():
            if value <= 0:
                raise ValueError(
                    f"{name} must be positive"
                )

        self.vector_register_words = (
            vector_register_words
        )

        self.scalar_registers = (
            scalar_registers
        )

        self.shared_memory_words = (
            shared_memory_words
        )

        self.max_resident_waves = (
            max_resident_waves
        )

        self.max_resident_workgroups = (
            max_resident_workgroups
        )


class KernelResourceUsage:
    def __init__(
        self,
        *,
        waves_per_workgroup=1,
        vector_registers_per_lane=0,
        scalar_registers_per_wave=0,
        shared_words_per_workgroup=0,
    ):
        if waves_per_workgroup <= 0:
            raise ValueError(
                "waves_per_workgroup must be positive"
            )

        if not (
            0
            <= vector_registers_per_lane
            <= VECTOR_REG_COUNT
        ):
            raise ValueError(
                "vector_registers_per_lane outside "
                "architectural register range"
            )

        if not (
            0
            <= scalar_registers_per_wave
            <= SCALAR_REG_COUNT
        ):
            raise ValueError(
                "scalar_registers_per_wave outside "
                "architectural register range"
            )

        if shared_words_per_workgroup < 0:
            raise ValueError(
                "shared_words_per_workgroup must "
                "be non-negative"
            )

        self.waves_per_workgroup = (
            waves_per_workgroup
        )

        self.vector_registers_per_lane = (
            vector_registers_per_lane
        )

        self.scalar_registers_per_wave = (
            scalar_registers_per_wave
        )

        self.shared_words_per_workgroup = (
            shared_words_per_workgroup
        )


def calculate_occupancy(
    config,
    usage,
):
    waves_per_workgroup = (
        usage.waves_per_workgroup
    )

    vector_words_per_wave = (
        usage.vector_registers_per_lane
        * WAVE_SIZE
    )

    vector_words_per_workgroup = (
        vector_words_per_wave
        * waves_per_workgroup
    )

    scalar_registers_per_workgroup = (
        usage.scalar_registers_per_wave
        * waves_per_workgroup
    )

    wave_slot_workgroups = (
        config.max_resident_waves
        // waves_per_workgroup
    )

    workgroup_slot_limit = (
        config.max_resident_workgroups
    )

    if vector_words_per_workgroup:
        vector_register_limit = (
            config.vector_register_words
            // vector_words_per_workgroup
        )
    else:
        vector_register_limit = (
            config.max_resident_workgroups
        )

    if scalar_registers_per_workgroup:
        scalar_register_limit = (
            config.scalar_registers
            // scalar_registers_per_workgroup
        )
    else:
        scalar_register_limit = (
            config.max_resident_workgroups
        )

    if usage.shared_words_per_workgroup:
        shared_memory_limit = (
            config.shared_memory_words
            // usage.shared_words_per_workgroup
        )
    else:
        shared_memory_limit = (
            config.max_resident_workgroups
        )

    limits = {
        "wave_slots": wave_slot_workgroups,
        "workgroup_slots": workgroup_slot_limit,
        "vector_registers":
            vector_register_limit,
        "scalar_registers":
            scalar_register_limit,
        "shared_memory":
            shared_memory_limit,
    }

    resident_workgroups = min(
        limits.values()
    )

    resident_waves = (
        resident_workgroups
        * waves_per_workgroup
    )

    if config.max_resident_waves:
        occupancy = (
            resident_waves
            / config.max_resident_waves
        )
    else:
        occupancy = 0.0

    limiting_resources = sorted(
        name
        for name, limit in limits.items()
        if limit == resident_workgroups
    )

    return {
        "waves_per_workgroup":
            waves_per_workgroup,

        "vector_words_per_wave":
            vector_words_per_wave,

        "vector_words_per_workgroup":
            vector_words_per_workgroup,

        "scalar_registers_per_workgroup":
            scalar_registers_per_workgroup,

        "shared_words_per_workgroup":
            usage.shared_words_per_workgroup,

        "resident_workgroups":
            resident_workgroups,

        "resident_waves":
            resident_waves,

        "occupancy":
            occupancy,

        "occupancy_percent":
            occupancy * 100.0,

        "limiting_resources":
            limiting_resources,

        "workgroup_limits":
            limits,
    }


def run_resident_wave_timing_experiment(
    program_words,
    occupancy_result,
    *,
    timing_config=None,
    initialize_wave=None,
):
    resident_waves = (
        occupancy_result[
            "resident_waves"
        ]
    )

    if resident_waves <= 0:
        raise RuntimeError(
            "Kernel has zero resident waves"
        )

    # This first bridge is intentionally restricted
    # to independent-wave throughput experiments.
    # Workgroup barriers and LDS require real
    # workgroup-level residency scheduling.
    forbidden = {
        Opcode.BARRIER,
        Opcode.LDSLOAD,
        Opcode.LDSSTORE,
    }

    for word in program_words:
        instr = decode(word)

        if instr.opcode in forbidden:
            raise ValueError(
                "Resident-wave timing experiment "
                "does not yet support BARRIER/LDS"
            )

    workgroup = WorkgroupState()

    waves = []

    for wave_id in range(resident_waves):
        wave = A0GPU(
            workgroup=workgroup,
            wave_id=wave_id,
        )

        wave.load_program(
            list(program_words)
        )

        if initialize_wave is not None:
            initialize_wave(
                wave,
                wave_id,
            )

        waves.append(wave)

    scheduler = TimingWorkgroupScheduler(
        waves,
        timing_config,
    )

    result = scheduler.run()

    result["resident_waves"] = (
        resident_waves
    )

    result["resident_workgroups"] = (
        occupancy_result[
            "resident_workgroups"
        ]
    )

    result["occupancy"] = (
        occupancy_result["occupancy"]
    )

    result["occupancy_percent"] = (
        occupancy_result[
            "occupancy_percent"
        ]
    )

    if result["cycles"]:
        result["waves_per_cycle"] = (
            resident_waves
            / result["cycles"]
        )
    else:
        result["waves_per_cycle"] = 0.0

    result["cycles_per_wave"] = (
        result["cycles"]
        / resident_waves
    )

    return result

class TimingLRUCache:
    def __init__(
        self,
        capacity_lines,
    ):
        if capacity_lines <= 0:
            raise ValueError(
                "capacity_lines must be positive"
            )

        self.capacity_lines = capacity_lines
        self.lines = []

    def access(self, line_id):
        if line_id not in self.lines:
            return False

        self.lines.remove(line_id)
        self.lines.append(line_id)

        return True

    def insert(self, line_id):
        if line_id in self.lines:
            self.lines.remove(line_id)
            self.lines.append(line_id)
            return False

        evicted = False

        if len(self.lines) >= self.capacity_lines:
            self.lines.pop(0)
            evicted = True

        self.lines.append(line_id)

        return evicted


class TimingCacheHierarchy:
    def __init__(self, config):
        self.config = config

        self.l1 = TimingLRUCache(
            config.l1_capacity_lines
        )

        self.l2 = TimingLRUCache(
            config.l2_capacity_lines
        )

        self.stats = {
            "cache_line_accesses": 0,
            "l1_hits": 0,
            "l1_misses": 0,
            "l2_hits": 0,
            "l2_misses": 0,
            "dram_accesses": 0,
            "l1_evictions": 0,
            "l2_evictions": 0,
        }

    def access_word_addresses(
        self,
        word_addresses,
    ):
        line_ids = sorted(
            {
                address
                // self.config.cache_line_words
                for address in word_addresses
            }
        )

        record = {
            "line_ids": line_ids,
            "line_count": len(line_ids),
            "l1_hits": 0,
            "l1_misses": 0,
            "l2_hits": 0,
            "l2_misses": 0,
            "dram_accesses": 0,
            "max_path_latency": 0,
        }

        for line_id in line_ids:
            self.stats[
                "cache_line_accesses"
            ] += 1

            if self.l1.access(line_id):
                self.stats["l1_hits"] += 1
                record["l1_hits"] += 1

                path_latency = (
                    self.config.l1_hit_latency
                )

            else:
                self.stats["l1_misses"] += 1
                record["l1_misses"] += 1

                if self.l2.access(line_id):
                    self.stats["l2_hits"] += 1
                    record["l2_hits"] += 1

                    path_latency = (
                        self.config.l2_hit_latency
                    )

                else:
                    self.stats["l2_misses"] += 1
                    self.stats["dram_accesses"] += 1

                    record["l2_misses"] += 1
                    record["dram_accesses"] += 1

                    path_latency = (
                        self.config.
                        global_memory_latency
                    )

                    if self.l2.insert(line_id):
                        self.stats[
                            "l2_evictions"
                        ] += 1

                if self.l1.insert(line_id):
                    self.stats[
                        "l1_evictions"
                    ] += 1

            record["max_path_latency"] = max(
                record["max_path_latency"],
                path_latency,
            )

        return record


class TimingConfig:
    VALID_SCHEDULER_POLICIES = {
        "lrr",
        "gto",
        "oldest_ready",
        "a0_adaptive_v0",
    }

    VALID_VECTOR_FRONTEND_MODELS = {
        "ideal",
        "rtl6b_coarse",
    }

    def __init__(
        self,
        *,
        issue_width=1,
        int_latency=1,
        scalar_latency=1,
        fp_add_latency=4,
        fp_mul_latency=4,
        fp_fma_latency=4,
        global_memory_latency=20,
        global_memory_transaction_penalty=1,
        cache_line_words=16,
        l1_capacity_lines=16,
        l2_capacity_lines=64,
        l1_hit_latency=2,
        l2_hit_latency=8,
        lds_latency=2,
        control_latency=1,
        int_issue_gap=1,
        scalar_issue_gap=1,
        fp_issue_gap=1,
        global_memory_issue_gap=1,
        lds_issue_gap=1,
        control_issue_gap=1,
        scheduler_policy="lrr",
        vector_frontend_model="ideal",
        physical_lanes=8,
        vrf_bank_count=4,
        vrf_read_ports_per_bank=1,
        vrf_read_latency=1,
        vrf_request_cycles=1,
        vector_retire_cycles=1,
    ):
        values = {
            "issue_width": issue_width,
            "int_latency": int_latency,
            "scalar_latency": scalar_latency,
            "fp_add_latency": fp_add_latency,
            "fp_mul_latency": fp_mul_latency,
            "fp_fma_latency": fp_fma_latency,
            "global_memory_latency": global_memory_latency,
            "cache_line_words": cache_line_words,
            "l1_capacity_lines": l1_capacity_lines,
            "l2_capacity_lines": l2_capacity_lines,
            "l1_hit_latency": l1_hit_latency,
            "l2_hit_latency": l2_hit_latency,
            "lds_latency": lds_latency,
            "control_latency": control_latency,
            "int_issue_gap": int_issue_gap,
            "scalar_issue_gap": scalar_issue_gap,
            "fp_issue_gap": fp_issue_gap,
            "global_memory_issue_gap": global_memory_issue_gap,
            "lds_issue_gap": lds_issue_gap,
            "control_issue_gap": control_issue_gap,
            "physical_lanes": physical_lanes,
            "vrf_bank_count": vrf_bank_count,
            "vrf_read_ports_per_bank": vrf_read_ports_per_bank,
            "vrf_read_latency": vrf_read_latency,
            "vrf_request_cycles": vrf_request_cycles,
            "vector_retire_cycles": vector_retire_cycles,
        }

        for name, value in values.items():
            if value <= 0:
                raise ValueError(
                    f"{name} must be positive"
                )

        if global_memory_transaction_penalty < 0:
            raise ValueError(
                "global_memory_transaction_penalty "
                "must be non-negative"
            )

        if scheduler_policy not in self.VALID_SCHEDULER_POLICIES:
            raise ValueError(
                "scheduler_policy must be one of "
                f"{sorted(self.VALID_SCHEDULER_POLICIES)}"
            )

        if (
            vector_frontend_model
            not in self.VALID_VECTOR_FRONTEND_MODELS
        ):
            raise ValueError(
                "vector_frontend_model must be one of "
                f"{sorted(self.VALID_VECTOR_FRONTEND_MODELS)}"
            )

        if physical_lanes > WAVE_SIZE:
            raise ValueError(
                "physical_lanes must not exceed WAVE_SIZE"
            )

        self.issue_width = issue_width

        self.int_latency = int_latency
        self.scalar_latency = scalar_latency

        self.fp_add_latency = fp_add_latency
        self.fp_mul_latency = fp_mul_latency
        self.fp_fma_latency = fp_fma_latency

        self.global_memory_latency = (
            global_memory_latency
        )

        self.global_memory_transaction_penalty = (
            global_memory_transaction_penalty
        )

        self.cache_line_words = cache_line_words
        self.l1_capacity_lines = l1_capacity_lines
        self.l2_capacity_lines = l2_capacity_lines

        self.l1_hit_latency = l1_hit_latency
        self.l2_hit_latency = l2_hit_latency

        self.lds_latency = lds_latency
        self.control_latency = control_latency

        self.int_issue_gap = int_issue_gap
        self.scalar_issue_gap = scalar_issue_gap
        self.fp_issue_gap = fp_issue_gap

        self.global_memory_issue_gap = (
            global_memory_issue_gap
        )

        self.lds_issue_gap = lds_issue_gap
        self.control_issue_gap = control_issue_gap

        self.scheduler_policy = scheduler_policy
        self.vector_frontend_model = vector_frontend_model

        self.physical_lanes = physical_lanes
        self.vrf_bank_count = vrf_bank_count
        self.vrf_read_ports_per_bank = (
            vrf_read_ports_per_bank
        )
        self.vrf_read_latency = vrf_read_latency
        self.vrf_request_cycles = vrf_request_cycles
        self.vector_retire_cycles = vector_retire_cycles


def timing_sources(instr):
    sources = []

    vector_binary = {
        Opcode.VADD,
        Opcode.VSUB,
        Opcode.VMUL,
        Opcode.VAND,
        Opcode.VOR,
        Opcode.VXOR,
        Opcode.VFADD,
        Opcode.VFSUB,
        Opcode.VFMUL,
    }

    if instr.opcode in vector_binary:
        sources.extend(
            [
                ("V", instr.src0),
                ("V", instr.src1),
            ]
        )

    elif instr.opcode == Opcode.VFFMA:
        sources.extend(
            [
                ("V", instr.src0),
                ("V", instr.src1),
                ("V", instr.src2),
            ]
        )

    elif instr.opcode in {
        Opcode.VCMP_EQ,
        Opcode.VCMP_LT,
        Opcode.VCMP_LE,
    }:
        sources.extend(
            [
                ("V", instr.src0),
                ("V", instr.src1),
            ]
        )

    elif instr.opcode == Opcode.VSTORE:
        sources.append(
            ("V", instr.src0)
        )

    elif instr.opcode == Opcode.VLOADX:
        sources.extend(
            [
                ("S", instr.src0),
                ("V", instr.src1),
            ]
        )

    elif instr.opcode == Opcode.VSTOREX:
        sources.extend(
            [
                ("S", instr.src0),
                ("V", instr.src1),
                ("V", instr.src2),
            ]
        )

    elif instr.opcode == Opcode.LDSLOAD:
        sources.append(
            ("V", instr.src0)
        )

    elif instr.opcode == Opcode.LDSSTORE:
        sources.extend(
            [
                ("V", instr.src0),
                ("V", instr.src1),
            ]
        )

    elif instr.opcode in {
        Opcode.SADD,
        Opcode.SSUB,
    }:
        sources.extend(
            [
                ("S", instr.src0),
                ("S", instr.src1),
            ]
        )

    elif instr.opcode == Opcode.SCMP_LT:
        sources.extend(
            [
                ("S", instr.src0),
                ("S", instr.src1),
            ]
        )

    elif instr.opcode == Opcode.BRA:
        sources.append(
            ("Q", instr.pred)
        )

    elif instr.opcode == Opcode.SPLIT:
        sources.append(
            ("P", instr.pred)
        )

    # Predicated vector instructions also consume
    # the selected vector predicate.
    if instr.flags & 0x1:
        sources.append(
            ("P", instr.pred)
        )

    return sources


RTL6B_SEQUENCED_VECTOR_OPCODES = {
    Opcode.VADD,
    Opcode.VSUB,
    Opcode.VMUL,
    Opcode.VAND,
    Opcode.VOR,
    Opcode.VXOR,
    Opcode.VCMP_EQ,
    Opcode.VCMP_LT,
    Opcode.VCMP_LE,
}


def timing_vector_source_registers(instr):
    return [
        index
        for kind, index in timing_sources(instr)
        if kind == "V"
    ]


def timing_vrf_bank_rounds(instr, config):
    if instr.opcode not in RTL6B_SEQUENCED_VECTOR_OPCODES:
        return 0

    sources = timing_vector_source_registers(instr)

    if not sources:
        return 0

    bank_counts = [0] * config.vrf_bank_count

    for register_index in sources:
        bank = register_index % config.vrf_bank_count
        bank_counts[bank] += 1

    return max(
        (
            count
            + config.vrf_read_ports_per_bank
            - 1
        )
        // config.vrf_read_ports_per_bank
        for count in bank_counts
    )


def timing_vector_frontend_hold(instr, config):
    if config.vector_frontend_model == "ideal":
        return 1

    if instr.opcode not in RTL6B_SEQUENCED_VECTOR_OPCODES:
        return 1

    bank_rounds = timing_vrf_bank_rounds(
        instr,
        config,
    )

    beat_count = (
        WAVE_SIZE
        + config.physical_lanes
        - 1
    ) // config.physical_lanes

    per_beat_cycles = (
        config.vrf_request_cycles
        + config.vrf_read_latency
        + max(1, bank_rounds)
    )

    return (
        beat_count * per_beat_cycles
        + config.vector_retire_cycles
    )


def timing_destinations(instr):
    if instr.opcode in {
        Opcode.VADD,
        Opcode.VSUB,
        Opcode.VMUL,
        Opcode.VAND,
        Opcode.VOR,
        Opcode.VXOR,
        Opcode.VFADD,
        Opcode.VFSUB,
        Opcode.VFMUL,
        Opcode.VFFMA,
        Opcode.VLOAD,
        Opcode.VLOADX,
        Opcode.LDSLOAD,
    }:
        return [
            ("V", instr.dst)
        ]

    if instr.opcode in {
        Opcode.VCMP_EQ,
        Opcode.VCMP_LT,
        Opcode.VCMP_LE,
    }:
        return [
            ("P", instr.pred)
        ]

    if instr.opcode in {
        Opcode.SADD,
        Opcode.SSUB,
        Opcode.SLOAD,
    }:
        return [
            ("S", instr.dst)
        ]

    if instr.opcode == Opcode.SCMP_LT:
        return [
            ("Q", instr.pred)
        ]

    return []


def timing_unit(instr):
    if instr.opcode in {
        Opcode.VFADD,
        Opcode.VFSUB,
        Opcode.VFMUL,
        Opcode.VFFMA,
    }:
        return "fp"

    if instr.opcode in {
        Opcode.VLOAD,
        Opcode.VSTORE,
        Opcode.VLOADX,
        Opcode.VSTOREX,
        Opcode.SLOAD,
        Opcode.SSTORE,
    }:
        return "global_memory"

    if instr.opcode in {
        Opcode.LDSLOAD,
        Opcode.LDSSTORE,
    }:
        return "lds"

    if instr.opcode in {
        Opcode.SADD,
        Opcode.SSUB,
        Opcode.SCMP_LT,
    }:
        return "scalar"

    if instr.opcode in {
        Opcode.JMP,
        Opcode.BRA,
        Opcode.SPLIT,
        Opcode.ELSE,
        Opcode.JOIN,
        Opcode.BARRIER,
        Opcode.HALT,
    }:
        return "control"

    return "int"


class TimingWorkgroupScheduler:
    def __init__(
        self,
        waves,
        config=None,
    ):
        self.waves = list(waves)

        if not self.waves:
            raise ValueError(
                "TimingWorkgroupScheduler requires "
                "at least one wave"
            )

        workgroup = self.waves[0].workgroup

        for wave in self.waves:
            if wave.workgroup is not workgroup:
                raise ValueError(
                    "All timing-scheduled waves must "
                    "share one WorkgroupState"
                )

        wave_ids = [
            wave.wave_id
            for wave in self.waves
        ]

        if len(set(wave_ids)) != len(wave_ids):
            raise ValueError(
                "Timing-scheduled waves require "
                "unique wave_id values"
            )

        if config is None:
            config = TimingConfig()

        self.config = config
        self.workgroup = workgroup

        self.cache = TimingCacheHierarchy(
            config
        )

        self.cache_access_trace = []

        self.cycle = 0
        self.instructions_issued = 0
        self.idle_cycles = 0

        self.dependency_stall_events = 0
        self.unit_stall_events = 0
        self.completion_stall_events = 0
        self.barrier_wait_events = 0

        self.latency_hidden_cycles = 0

        self.barrier_epoch = 0
        self.barrier_releases = 0

        self.round_robin_cursor = 0
        self.last_issued_wave_id = None
        self.last_issued_unit = None
        self.last_global_issue_wave_id = None

        self.issue_trace = []
        self.scheduler_switches = 0
        self.current_issue_run = 0
        self.max_consecutive_issue_run = 0

        self.frontend_stall_events = 0
        self.vrf_bank_conflict_instructions = 0
        self.vrf_bank_conflict_extra_rounds = 0
        self.vrf_conflict_penalty_cycles = 0
        self.vrf_frontend_hold_cycles = 0

        self.wave_issue_counts = {
            wave.wave_id: 0
            for wave in self.waves
        }

        self.wave_last_issue_cycle = {
            wave.wave_id: None
            for wave in self.waves
        }

        self.wave_max_issue_gap = {
            wave.wave_id: 0
            for wave in self.waves
        }

        self.wave_next_issue = {
            wave.wave_id: 0
            for wave in self.waves
        }

        self.ready = {}

        self.outstanding_until = {}

        for wave in self.waves:
            self.ready[wave.wave_id] = {
                "V": [0] * VECTOR_REG_COUNT,
                "S": [0] * SCALAR_REG_COUNT,
                "P": [0] * PREDICATE_REG_COUNT,
                "Q": [0] * SCALAR_PREDICATE_REG_COUNT,
            }

            self.outstanding_until[
                wave.wave_id
            ] = 0

        self.unit_next_issue = {
            "int": 0,
            "scalar": 0,
            "fp": 0,
            "global_memory": 0,
            "lds": 0,
            "control": 0,
        }

    def wave_index(self, wave_id):
        for index, wave in enumerate(self.waves):
            if wave.wave_id == wave_id:
                return index

        raise KeyError(
            f"Unknown wave_id: {wave_id}"
        )

    def predicted_memory_line_ids(
        self,
        wave,
        instr,
    ):
        if instr.opcode not in {
            Opcode.VLOADX,
            Opcode.VSTOREX,
        }:
            return set()

        immediate = sign_extend_24(
            instr.imm24
        )
        scalar_base = wave.scalar_regs[
            instr.src0
        ]

        line_ids = set()

        for thread in range(WAVE_SIZE):
            if not wave.thread_enabled(
                instr,
                thread,
            ):
                continue

            address = (
                scalar_base
                + wave.vector_regs[
                    instr.src1
                ][thread]
                + immediate
            )

            if not 0 <= address < MEMORY_WORDS:
                continue

            line_ids.add(
                address
                // self.config.cache_line_words
            )

        return line_ids

    def memory_working_set_exceeds_l2(self):
        line_ids = set()

        for wave in self.waves:
            if wave.halted:
                continue

            if wave.waiting_at_barrier:
                continue

            instr = self.next_instruction(wave)

            line_ids.update(
                self.predicted_memory_line_ids(
                    wave,
                    instr,
                )
            )

        return (
            len(line_ids)
            > self.config.l2_capacity_lines
        )

    def candidate_indices(self):
        count = len(self.waves)

        if self.config.scheduler_policy == "lrr":
            return [
                (self.round_robin_cursor + offset)
                % count
                for offset in range(count)
            ]

        if self.config.scheduler_policy == "gto":
            order = []

            if self.last_issued_wave_id is not None:
                order.append(
                    self.wave_index(
                        self.last_issued_wave_id
                    )
                )

            order.extend(
                index
                for index in range(count)
                if index not in order
            )

            return order

        if (
            self.config.scheduler_policy
            == "a0_adaptive_v0"
        ):
            lrr_order = [
                (self.round_robin_cursor + offset)
                % count
                for offset in range(count)
            ]

            if (
                self.last_issued_wave_id is not None
                and self.last_issued_unit
                    == "global_memory"
                and self.memory_working_set_exceeds_l2()
            ):
                last_index = self.wave_index(
                    self.last_issued_wave_id
                )

                last_wave = self.waves[last_index]

                if (
                    not last_wave.halted
                    and not last_wave.waiting_at_barrier
                ):
                    next_instr = self.next_instruction(
                        last_wave
                    )

                    if (
                        timing_unit(next_instr)
                        == "global_memory"
                    ):
                        return [
                            last_index,
                            *(
                                index
                                for index in lrr_order
                                if index != last_index
                            ),
                        ]

            return lrr_order

        # oldest_ready: the wave that has gone
        # longest without an issue gets first choice.
        def age_key(index):
            wave_id = self.waves[index].wave_id
            last = self.wave_last_issue_cycle[wave_id]

            if last is None:
                return (-1, index)

            return (last, index)

        return sorted(
            range(count),
            key=age_key,
        )

    def next_instruction(self, wave):
        if wave.halted:
            return None

        if not (
            0 <= wave.pc < len(wave.program_words)
        ):
            raise RuntimeError(
                f"Wave {wave.wave_id} PC outside "
                f"instruction memory: {wave.pc}"
            )

        return decode(
            wave.program_words[wave.pc]
        )

    def resource_ready_cycle(
        self,
        wave,
        resource,
    ):
        kind, index = resource

        return self.ready[
            wave.wave_id
        ][kind][index]

    def unit_gap(self, unit):
        if unit == "fp":
            return self.config.fp_issue_gap

        if unit == "global_memory":
            return (
                self.config.global_memory_issue_gap
            )

        if unit == "lds":
            return self.config.lds_issue_gap

        if unit == "scalar":
            return self.config.scalar_issue_gap

        if unit == "control":
            return self.config.control_issue_gap

        return self.config.int_issue_gap

    def base_latency(self, instr):
        if instr.opcode in {
            Opcode.VFADD,
            Opcode.VFSUB,
        }:
            return self.config.fp_add_latency

        if instr.opcode == Opcode.VFMUL:
            return self.config.fp_mul_latency

        if instr.opcode == Opcode.VFFMA:
            return self.config.fp_fma_latency

        if instr.opcode in {
            Opcode.VLOAD,
            Opcode.VSTORE,
            Opcode.VLOADX,
            Opcode.VSTOREX,
            Opcode.SLOAD,
            Opcode.SSTORE,
        }:
            return self.config.global_memory_latency

        if instr.opcode in {
            Opcode.LDSLOAD,
            Opcode.LDSSTORE,
        }:
            return self.config.lds_latency

        if instr.opcode in {
            Opcode.SADD,
            Opcode.SSUB,
            Opcode.SCMP_LT,
        }:
            return self.config.scalar_latency

        if timing_unit(instr) == "control":
            return self.config.control_latency

        return self.config.int_latency

    def effective_latency(
        self,
        wave,
        instr,
        trace_length_before,
    ):
        if instr.opcode in {
            Opcode.VLOADX,
            Opcode.VSTOREX,
        }:
            if (
                len(wave.memory_trace)
                > trace_length_before
            ):
                memory_record = (
                    wave.memory_trace[-1]
                )

                word_addresses = (
                    memory_record.get(
                        "word_addresses",
                        [],
                    )
                )

                cache_record = (
                    self.cache.
                    access_word_addresses(
                        word_addresses
                    )
                )

                cache_record["opcode"] = (
                    instr.opcode.name
                )

                cache_record["wave_id"] = (
                    wave.wave_id
                )

                cache_record["transactions"] = (
                    memory_record[
                        "transactions"
                    ]
                )

                self.cache_access_trace.append(
                    cache_record
                )

                if word_addresses:
                    latency = cache_record[
                        "max_path_latency"
                    ]
                else:
                    latency = 1

                transactions = (
                    memory_record[
                        "transactions"
                    ]
                )

                latency += (
                    max(
                        0,
                        transactions - 1,
                    )
                    * self.config.
                    global_memory_transaction_penalty
                )

                return latency

        return self.base_latency(instr)

    def release_barrier_if_complete(self):
        waiting = [
            wave
            for wave in self.waves
            if wave.waiting_at_barrier
        ]

        if not waiting:
            return False

        halted = [
            wave
            for wave in self.waves
            if wave.halted
        ]

        if halted:
            raise RuntimeError(
                "Timing barrier deadlock: "
                f"waiting_waves="
                f"{[w.wave_id for w in waiting]} "
                f"halted_waves="
                f"{[w.wave_id for w in halted]}"
            )

        if len(waiting) != len(self.waves):
            return False

        self.barrier_epoch += 1
        self.barrier_releases += 1

        for wave in self.waves:
            wave.waiting_at_barrier = False
            wave.barrier_epoch = (
                self.barrier_epoch
            )

        return True

    def can_issue(
        self,
        wave,
        instr,
    ):
        if (
            self.wave_next_issue[wave.wave_id]
            > self.cycle
        ):
            return False, "frontend"

        unit = timing_unit(instr)

        if (
            self.unit_next_issue[unit]
            > self.cycle
        ):
            return False, "unit"

        sources = timing_sources(instr)

        for resource in sources:
            if (
                self.resource_ready_cycle(
                    wave,
                    resource,
                )
                > self.cycle
            ):
                return False, "dependency"

        # HALT and BARRIER behave as completion
        # points in this first timing model.
        if instr.opcode in {
            Opcode.HALT,
            Opcode.BARRIER,
        }:
            if (
                self.outstanding_until[
                    wave.wave_id
                ]
                > self.cycle
            ):
                return False, "completion"

        return True, None

    def issue(
        self,
        wave,
        instr,
    ):
        unit = timing_unit(instr)
        wave_id = wave.wave_id
        pc_before = wave.pc

        trace_length_before = len(
            wave.memory_trace
        )

        frontend_hold = timing_vector_frontend_hold(
            instr,
            self.config,
        )

        bank_rounds = timing_vrf_bank_rounds(
            instr,
            self.config,
        )

        wave.step()

        latency = self.effective_latency(
            wave,
            instr,
            trace_length_before,
        )

        completion_latency = max(
            latency,
            frontend_hold,
        )

        completion_cycle = (
            self.cycle + completion_latency
        )

        for kind, index in timing_destinations(
            instr
        ):
            self.ready[
                wave_id
            ][kind][index] = (
                completion_cycle
            )

        self.outstanding_until[
            wave_id
        ] = max(
            self.outstanding_until[
                wave_id
            ],
            completion_cycle,
        )

        self.wave_next_issue[wave_id] = (
            self.cycle + frontend_hold
        )

        self.unit_next_issue[unit] = (
            self.cycle
            + self.unit_gap(unit)
        )

        if bank_rounds > 1:
            extra_rounds = bank_rounds - 1
            beat_count = (
                WAVE_SIZE
                + self.config.physical_lanes
                - 1
            ) // self.config.physical_lanes

            self.vrf_bank_conflict_instructions += 1
            self.vrf_bank_conflict_extra_rounds += (
                extra_rounds
            )

            if (
                self.config.vector_frontend_model
                == "rtl6b_coarse"
            ):
                self.vrf_conflict_penalty_cycles += (
                    beat_count * extra_rounds
                )

        if frontend_hold > 1:
            self.vrf_frontend_hold_cycles += (
                frontend_hold - 1
            )

        last_cycle = self.wave_last_issue_cycle[
            wave_id
        ]

        if last_cycle is not None:
            gap = self.cycle - last_cycle
            self.wave_max_issue_gap[wave_id] = max(
                self.wave_max_issue_gap[wave_id],
                gap,
            )

        self.wave_last_issue_cycle[wave_id] = (
            self.cycle
        )
        self.wave_issue_counts[wave_id] += 1

        if self.last_global_issue_wave_id is None:
            self.current_issue_run = 1

        elif self.last_global_issue_wave_id == wave_id:
            self.current_issue_run += 1

        else:
            self.scheduler_switches += 1
            self.current_issue_run = 1

        self.max_consecutive_issue_run = max(
            self.max_consecutive_issue_run,
            self.current_issue_run,
        )

        self.last_global_issue_wave_id = wave_id
        self.last_issued_wave_id = wave_id
        self.last_issued_unit = unit

        self.issue_trace.append(
            {
                "cycle": self.cycle,
                "wave_id": wave_id,
                "pc": pc_before,
                "opcode": instr.opcode.name,
                "frontend_hold": frontend_hold,
                "vrf_bank_rounds": bank_rounds,
            }
        )

        self.instructions_issued += 1

    def run(
        self,
        max_cycles=100000,
    ):
        while True:
            if all(
                wave.halted
                for wave in self.waves
            ):
                break

            if self.cycle >= max_cycles:
                raise RuntimeError(
                    "Maximum timing cycle count "
                    f"exceeded: {max_cycles}"
                )

            self.release_barrier_if_complete()

            for wave in self.waves:
                if wave.waiting_at_barrier:
                    self.barrier_wait_events += 1

            latency_blocked_at_cycle_start = False

            for wave in self.waves:
                if wave.halted:
                    continue

                if wave.waiting_at_barrier:
                    continue

                instr = self.next_instruction(
                    wave
                )

                can_issue, reason = (
                    self.can_issue(
                        wave,
                        instr,
                    )
                )

                if (
                    not can_issue
                    and reason in {
                        "dependency",
                        "completion",
                    }
                ):
                    latency_blocked_at_cycle_start = True
                    break

            issued_this_cycle = 0
            issued_wave_ids = set()

            dependency_blocked = False

            attempts = 0

            while (
                issued_this_cycle
                < self.config.issue_width
                and attempts < len(self.waves)
            ):
                selected = None
                selected_index = None

                for index in self.candidate_indices():
                    wave = self.waves[index]

                    if wave.wave_id in issued_wave_ids:
                        continue

                    if wave.halted:
                        continue

                    if wave.waiting_at_barrier:
                        continue

                    instr = self.next_instruction(
                        wave
                    )

                    can_issue, reason = (
                        self.can_issue(
                            wave,
                            instr,
                        )
                    )

                    if can_issue:
                        selected = (
                            wave,
                            instr,
                        )

                        selected_index = index
                        break

                    if reason == "dependency":
                        self.dependency_stall_events += 1
                        dependency_blocked = True

                    elif reason == "frontend":
                        self.frontend_stall_events += 1

                    elif reason == "unit":
                        self.unit_stall_events += 1

                    elif reason == "completion":
                        self.completion_stall_events += 1
                        dependency_blocked = True

                attempts += 1

                if selected is None:
                    break

                wave, instr = selected

                self.issue(
                    wave,
                    instr,
                )

                issued_wave_ids.add(
                    wave.wave_id
                )

                issued_this_cycle += 1

                self.round_robin_cursor = (
                    selected_index + 1
                ) % len(self.waves)

                self.release_barrier_if_complete()

            if issued_this_cycle == 0:
                self.idle_cycles += 1

            elif (
                latency_blocked_at_cycle_start
                or dependency_blocked
            ):
                self.latency_hidden_cycles += 1

            self.cycle += 1

        # HALT is treated as a completion point, so
        # no architectural work should remain in flight.
        return self.summary()

    def summary(self):
        if self.cycle:
            ipc = (
                self.instructions_issued
                / self.cycle
            )

            utilization = (
                self.instructions_issued
                / (
                    self.cycle
                    * self.config.issue_width
                )
            )
        else:
            ipc = 0.0
            utilization = 0.0

        return {
            "cycles": self.cycle,
            "instructions_issued": (
                self.instructions_issued
            ),
            "ipc": ipc,
            "scheduler_utilization": utilization,
            "idle_cycles": self.idle_cycles,
            "dependency_stall_events": (
                self.dependency_stall_events
            ),
            "unit_stall_events": (
                self.unit_stall_events
            ),
            "completion_stall_events": (
                self.completion_stall_events
            ),
            "barrier_wait_events": (
                self.barrier_wait_events
            ),
            "latency_hidden_cycles": (
                self.latency_hidden_cycles
            ),
            "barrier_releases": (
                self.barrier_releases
            ),
            "scheduler_policy": (
                self.config.scheduler_policy
            ),
            "vector_frontend_model": (
                self.config.vector_frontend_model
            ),
            "scheduler_switches": (
                self.scheduler_switches
            ),
            "max_consecutive_issue_run": (
                self.max_consecutive_issue_run
            ),
            "frontend_stall_events": (
                self.frontend_stall_events
            ),
            "vrf_bank_conflict_instructions": (
                self.vrf_bank_conflict_instructions
            ),
            "vrf_bank_conflict_extra_rounds": (
                self.vrf_bank_conflict_extra_rounds
            ),
            "vrf_conflict_penalty_cycles": (
                self.vrf_conflict_penalty_cycles
            ),
            "vrf_frontend_hold_cycles": (
                self.vrf_frontend_hold_cycles
            ),
            "wave_issue_counts": dict(
                self.wave_issue_counts
            ),
            "wave_max_issue_gap": dict(
                self.wave_max_issue_gap
            ),
            "cache_line_accesses": (
                self.cache.stats[
                    "cache_line_accesses"
                ]
            ),
            "l1_hits": self.cache.stats[
                "l1_hits"
            ],
            "l1_misses": self.cache.stats[
                "l1_misses"
            ],
            "l2_hits": self.cache.stats[
                "l2_hits"
            ],
            "l2_misses": self.cache.stats[
                "l2_misses"
            ],
            "dram_accesses": self.cache.stats[
                "dram_accesses"
            ],
            "l1_evictions": self.cache.stats[
                "l1_evictions"
            ],
            "l2_evictions": self.cache.stats[
                "l2_evictions"
            ],
        }


def mask_string(mask):
    return "".join(
        "1" if value else "0"
        for value in mask
    )


def main():
    gpu = A0GPU()

    for thread in range(WAVE_SIZE):
        # Thread ID
        gpu.vector_regs[1][thread] = thread

        # Compare against 16
        gpu.vector_regs[2][thread] = 16

        # Initial value
        gpu.vector_regs[3][thread] = 100

        # THEN path: +7
        gpu.vector_regs[4][thread] = 7

        # ELSE path: *2
        gpu.vector_regs[5][thread] = 2

    source = """
        VCMP_LT P0, V1, V2

        SPLIT P0

        VADD V3, V3, V4

        ELSE

        VMUL V3, V3, V5

        JOIN

        VSTORE V3, 0
        HALT
    """

    machine_code = assemble_source(source)

    print("A0-SIM3 machine program")
    print()

    for pc, word in enumerate(machine_code):
        print(f"{pc:04d}: 0x{word:016X}")

    print()
    print("A0-SIM3 execution")
    print()

    gpu.load_program(machine_code)

    # Execute VCMP_LT first so P0 can be inspected.
    gpu.step()

    print()
    print("P0 after VCMP_LT:")
    print(mask_string(gpu.predicate_regs[0]))
    print()

    while not gpu.halted:
        gpu.step()

    print()
    print("A0-SIM3 verification")
    print()

    passed = 0

    for thread in range(WAVE_SIZE):
        expected = 107 if thread < 16 else 200
        actual = gpu.memory[thread]

        status = "PASS" if actual == expected else "FAIL"

        if status == "PASS":
            passed += 1

        print(
            f"thread={thread:02d} "
            f"predicate={int(gpu.predicate_regs[0][thread])} "
            f"result={actual:3d} "
            f"expected={expected:3d} "
            f"{status}"
        )

    print()
    print(
        f"A0-SIM3 result: "
        f"{passed}/{WAVE_SIZE} threads passed"
    )

    if passed != WAVE_SIZE:
        raise SystemExit(1)

    if gpu.reconvergence_stack:
        raise RuntimeError(
            "Reconvergence stack not empty after program"
        )

    if not all(gpu.exec_mask):
        raise RuntimeError(
            "EXEC_MASK was not fully restored after JOIN"
        )

    print("A0-SIM3 divergent execution: PASS")


if __name__ == "__main__":
    main()
