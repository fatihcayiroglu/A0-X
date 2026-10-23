import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = ROOT / "sim"

sys.path.insert(0, str(SIM_DIR))


from a0_asm import assemble_source
from a0_isa import Instruction, Opcode, decode, encode
from a0_sim import A0GPU, WAVE_SIZE, WorkgroupState, WorkgroupScheduler, f32_from_bits, f32_to_bits
from a0_sim import TimingConfig, TimingWorkgroupScheduler
from a0_sim import OccupancyConfig, KernelResourceUsage, calculate_occupancy, run_resident_wave_timing_experiment


class A0RegressionTests(unittest.TestCase):
    def run_silently(self, gpu):
        with redirect_stdout(io.StringIO()):
            gpu.run()

    def test_isa_encode_decode_round_trip(self):
        original = Instruction(
            opcode=Opcode.VADD,
            dst=3,
            src0=1,
            src1=2,
        )

        word = encode(original)
        decoded = decode(word)

        self.assertEqual(
            word,
            0x0100C10800000000,
        )

        self.assertEqual(
            decoded,
            original,
        )

    def test_sim1_binary_execution(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 100 + thread
            gpu.vector_regs[5][thread] = 2
            gpu.vector_regs[7][thread] = 10

        source = """
            VADD   V3, V1, V2
            VMUL   V4, V3, V5
            VSUB   V6, V4, V7
            VSTORE V6, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                (thread + (100 + thread)) * 2
            ) - 10

            self.assertEqual(
                gpu.memory[thread],
                expected,
            )

    def test_sim2_predicated_execution(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 16
            gpu.vector_regs[3][thread] = 100
            gpu.vector_regs[4][thread] = 7

        source = """
            VCMP_LT P0, V1, V2
            @P0 VADD V3, V3, V4
            VSTORE V3, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                107
                if thread < 16
                else 100
            )

            self.assertEqual(
                gpu.memory[thread],
                expected,
            )

    def test_sim3_divergence_and_reconvergence(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 16
            gpu.vector_regs[3][thread] = 100
            gpu.vector_regs[4][thread] = 7
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

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                107
                if thread < 16
                else 200
            )

            self.assertEqual(
                gpu.memory[thread],
                expected,
            )

        self.assertEqual(
            gpu.reconvergence_stack,
            [],
        )

        self.assertTrue(
            all(gpu.exec_mask)
        )

    def test_asm1_forward_label_pc_relative_jump(self):
        source = """
            VADD V3, V1, V2
            JMP store
            VMUL V3, V3, V5
        store:
            VSTORE V3, 0
            HALT
        """

        words = assemble_source(source)

        jump = decode(words[1])

        self.assertEqual(
            jump.opcode,
            Opcode.JMP,
        )

        # JMP is at PC=1.
        # Next PC is 2.
        # Target 'store' is PC=3.
        # Therefore relative offset = +1.
        self.assertEqual(
            jump.imm24,
            1,
        )

    def test_asm1_backward_label_signed_offset(self):
        source = """
        start:
            VADD V3, V1, V2
            JMP start
        """

        words = assemble_source(source)

        jump = decode(words[1])

        # JMP at PC=1:
        # next PC = 2
        # target = 0
        # offset = -2
        #
        # Signed -2 represented in IMM24:
        # 0xFFFFFE
        self.assertEqual(
            jump.imm24,
            0xFFFFFE,
        )

    def test_sim4_jmp_skips_instruction(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 100 + thread
            gpu.vector_regs[5][thread] = 2

        source = """
            VADD V3, V1, V2

            JMP store

            VMUL V3, V3, V5

        store:
            VSTORE V3, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = thread + (100 + thread)

            self.assertEqual(
                gpu.memory[thread],
                expected,
            )

    def test_sim5_scalar_add(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 10
        gpu.scalar_regs[1] = 7

        source = """
            SADD S2, S0, S1
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        self.assertEqual(
            gpu.scalar_regs[2],
            17,
        )

    def test_sim5_backward_bra_encoding(self):
        source = """
        loop:
            SADD S0, S0, S1
            SCMP_LT Q0, S0, S2
            BRA Q0, loop
            HALT
        """

        words = assemble_source(source)

        branch = decode(words[2])

        self.assertEqual(
            branch.opcode,
            Opcode.BRA,
        )

        # BRA is at PC 2.
        # NEXT_PC is 3.
        # loop is PC 0.
        # OFFSET = 0 - 3 = -3.
        self.assertEqual(
            branch.imm24,
            0xFFFFFD,
        )

        self.assertEqual(
            branch.pred,
            0,
        )

    def test_sim5_uniform_loop(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 0
        gpu.scalar_regs[1] = 1
        gpu.scalar_regs[2] = 5

        source = """
        loop:
            SADD S0, S0, S1
            SCMP_LT Q0, S0, S2
            BRA Q0, loop
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        self.assertEqual(
            gpu.scalar_regs[0],
            5,
        )

        self.assertFalse(
            gpu.scalar_predicate_regs[0]
        )

        self.assertTrue(
            all(gpu.exec_mask)
        )

    def test_sim6_vector_load_add_store(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.memory[100 + thread] = thread
            gpu.vector_regs[3][thread] = 10

        source = """
            VLOAD  V1, 100
            VADD   V2, V1, V3
            VSTORE V2, 200
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.memory[200 + thread],
                thread + 10,
            )

    def test_sim6_predicated_vector_load(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 16

            # Sentinel value proves inactive lanes are preserved.
            gpu.vector_regs[3][thread] = 77

            gpu.memory[100 + thread] = 1000 + thread

        source = """
            VCMP_LT P0, V1, V2
            @P0 VLOAD V3, 100
            VSTORE V3, 200
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                1000 + thread
                if thread < 16
                else 77
            )

            self.assertEqual(
                gpu.memory[200 + thread],
                expected,
            )

    def test_sim6_scalar_load_store(self):
        gpu = A0GPU()

        gpu.memory[10] = 0x12345678

        source = """
            SLOAD  S3, 10
            SSTORE S3, 20
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        self.assertEqual(
            gpu.scalar_regs[3],
            0x12345678,
        )

        self.assertEqual(
            gpu.memory[20],
            0x12345678,
        )

    def test_sim6_vector_load_bounds_check(self):
        gpu = A0GPU()

        source = """
            VLOAD V1, 1000
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        with self.assertRaises(RuntimeError):
            self.run_silently(gpu)

    def test_sim7_indexed_vector_load_store(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 100
        gpu.scalar_regs[1] = 300

        for thread in range(WAVE_SIZE):
            offset = thread * 2

            gpu.vector_regs[1][thread] = offset
            gpu.vector_regs[3][thread] = 5

            gpu.memory[100 + offset] = 1000 + thread

        source = """
            VLOADX  V2, S0, V1, 0
            VADD    V4, V2, V3
            VSTOREX V4, S1, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            address = 300 + (thread * 2)

            self.assertEqual(
                gpu.memory[address],
                1005 + thread,
            )

    def test_sim7_signed_indexed_immediate(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 200

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.memory[190 + thread] = 500 + thread

        source = """
            VLOADX V2, S0, V1, -10
            HALT
        """

        words = assemble_source(source)

        decoded = decode(words[0])

        self.assertEqual(
            decoded.opcode,
            Opcode.VLOADX,
        )

        self.assertEqual(
            decoded.imm24,
            0xFFFFF6,
        )

        gpu.load_program(words)

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[2][thread],
                500 + thread,
            )

    def test_sim7_masked_invalid_addresses_do_not_fault(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 100

        for thread in range(WAVE_SIZE):
            # Comparison inputs.
            gpu.vector_regs[10][thread] = thread
            gpu.vector_regs[11][thread] = 16

            # Inactive-lane destination sentinel.
            gpu.vector_regs[3][thread] = 77

            if thread < 16:
                gpu.vector_regs[1][thread] = thread
                gpu.memory[100 + thread] = 2000 + thread
            else:
                # Deliberately invalid, but these lanes will be masked.
                gpu.vector_regs[1][thread] = 5000

        source = """
            VCMP_LT P0, V10, V11
            @P0 VLOADX V3, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                2000 + thread
                if thread < 16
                else 77
            )

            self.assertEqual(
                gpu.vector_regs[3][thread],
                expected,
            )

    def test_sim7_active_invalid_address_faults(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 1000

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = 100 + thread

        source = """
            VLOADX V2, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        with self.assertRaises(RuntimeError):
            self.run_silently(gpu)

    def test_sim8_contiguous_coalescing(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 0

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.memory[thread] = 100 + thread

        source = """
            VLOADX V2, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        metrics = gpu.memory_trace[-1]

        self.assertEqual(
            metrics["lane_requests"],
            32,
        )

        self.assertEqual(
            metrics["unique_words"],
            32,
        )

        self.assertEqual(
            metrics["transactions"],
            4,
        )

        self.assertEqual(
            metrics["useful_bytes"],
            128,
        )

        self.assertEqual(
            metrics["transferred_bytes"],
            128,
        )

        self.assertAlmostEqual(
            metrics["coalescing_efficiency"],
            1.0,
        )

    def test_sim8_stride8_coalescing(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 0

        for thread in range(WAVE_SIZE):
            address = thread * 8
            gpu.vector_regs[1][thread] = address
            gpu.memory[address] = 200 + thread

        source = """
            VLOADX V2, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        metrics = gpu.memory_trace[-1]

        self.assertEqual(
            metrics["lane_requests"],
            32,
        )

        self.assertEqual(
            metrics["transactions"],
            32,
        )

        self.assertEqual(
            metrics["useful_bytes"],
            128,
        )

        self.assertEqual(
            metrics["transferred_bytes"],
            1024,
        )

        self.assertAlmostEqual(
            metrics["coalescing_efficiency"],
            0.125,
        )

    def test_sim8_mask_reduces_transactions(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 0

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[10][thread] = thread
            gpu.vector_regs[11][thread] = 16
            gpu.memory[thread] = 300 + thread

        source = """
            VCMP_LT P0, V10, V11
            @P0 VLOADX V2, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        metrics = gpu.memory_trace[-1]

        self.assertEqual(
            metrics["lane_requests"],
            16,
        )

        self.assertEqual(
            metrics["unique_words"],
            16,
        )

        self.assertEqual(
            metrics["transactions"],
            2,
        )

        self.assertAlmostEqual(
            metrics["coalescing_efficiency"],
            1.0,
        )

    def test_sim8_same_address_broadcast_metric(self):
        gpu = A0GPU()

        gpu.scalar_regs[0] = 0
        gpu.memory[0] = 0xABCDEF

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = 0

        source = """
            VLOADX V2, S0, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        metrics = gpu.memory_trace[-1]

        self.assertEqual(
            metrics["lane_requests"],
            32,
        )

        self.assertEqual(
            metrics["unique_words"],
            1,
        )

        self.assertEqual(
            metrics["transactions"],
            1,
        )

        self.assertAlmostEqual(
            metrics["coalescing_efficiency"],
            0.125,
        )

        self.assertAlmostEqual(
            metrics["broadcast_factor"],
            32.0,
        )

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[2][thread],
                0xABCDEF,
            )

    def test_sim9_shared_memory_single_wave(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = (
                1000 + thread
            )

        source = """
            LDSSTORE V2, V1, 0
            LDSLOAD  V3, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[3][thread],
                1000 + thread,
            )

    def test_sim9_shared_memory_between_waves(self):
        workgroup = WorkgroupState()

        wave0 = A0GPU(
            workgroup=workgroup,
            wave_id=0,
        )

        wave1 = A0GPU(
            workgroup=workgroup,
            wave_id=1,
        )

        for thread in range(WAVE_SIZE):
            wave0.vector_regs[1][thread] = thread
            wave0.vector_regs[2][thread] = (
                2000 + thread
            )

            wave1.vector_regs[1][thread] = thread

        producer = """
            LDSSTORE V2, V1, 0
            HALT
        """

        consumer = """
            LDSLOAD V3, V1, 0
            HALT
        """

        wave0.load_program(
            assemble_source(producer)
        )

        wave1.load_program(
            assemble_source(consumer)
        )

        self.run_silently(wave0)
        self.run_silently(wave1)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                wave1.vector_regs[3][thread],
                2000 + thread,
            )

        self.assertIs(
            wave0.workgroup,
            wave1.workgroup,
        )

        self.assertEqual(
            wave0.wave_id,
            0,
        )

        self.assertEqual(
            wave1.wave_id,
            1,
        )

    def test_sim9_predicated_shared_store(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread

            gpu.vector_regs[2][thread] = (
                3000 + thread
            )

            gpu.vector_regs[10][thread] = thread
            gpu.vector_regs[11][thread] = 16

            gpu.workgroup.shared_memory[
                thread
            ] = 77

        source = """
            VCMP_LT P0, V10, V11
            @P0 LDSSTORE V2, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                3000 + thread
                if thread < 16
                else 77
            )

            self.assertEqual(
                gpu.workgroup.shared_memory[
                    thread
                ],
                expected,
            )

    def test_sim9_shared_memory_bounds(self):
        workgroup = WorkgroupState(
            shared_words=32
        )

        gpu = A0GPU(
            workgroup=workgroup,
        )

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = (
                thread + 1
            )

        source = """
            LDSLOAD V2, V1, 0
            HALT
        """

        gpu.load_program(
            assemble_source(source)
        )

        with self.assertRaises(
            RuntimeError
        ):
            self.run_silently(gpu)

    def test_sim10_barrier_encoding(self):
        words = assemble_source(
            """
            BARRIER
            HALT
            """
        )

        barrier = decode(words[0])

        self.assertEqual(
            barrier.opcode,
            Opcode.BARRIER,
        )

    def test_sim10_producer_consumer_barrier(self):
        workgroup = WorkgroupState()

        producer = A0GPU(
            workgroup=workgroup,
            wave_id=0,
        )

        consumer = A0GPU(
            workgroup=workgroup,
            wave_id=1,
        )

        for thread in range(WAVE_SIZE):
            producer.vector_regs[1][thread] = thread

            producer.vector_regs[2][thread] = (
                4000 + thread
            )

            consumer.vector_regs[1][thread] = thread

        producer.load_program(
            assemble_source(
                """
                LDSSTORE V2, V1, 0
                BARRIER
                HALT
                """
            )
        )

        consumer.load_program(
            assemble_source(
                """
                BARRIER
                LDSLOAD V3, V1, 0
                HALT
                """
            )
        )

        scheduler = WorkgroupScheduler(
            [producer, consumer]
        )

        self.run_silently(
            scheduler
        )

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                consumer.vector_regs[3][thread],
                4000 + thread,
            )

        self.assertEqual(
            scheduler.barrier_releases,
            1,
        )

        self.assertEqual(
            scheduler.barrier_epoch,
            1,
        )

    def test_sim10_multiple_barrier_epochs(self):
        workgroup = WorkgroupState()

        wave0 = A0GPU(
            workgroup=workgroup,
            wave_id=0,
        )

        wave1 = A0GPU(
            workgroup=workgroup,
            wave_id=1,
        )

        program = assemble_source(
            """
            BARRIER
            BARRIER
            HALT
            """
        )

        wave0.load_program(program)
        wave1.load_program(program)

        scheduler = WorkgroupScheduler(
            [wave0, wave1]
        )

        self.run_silently(
            scheduler
        )

        self.assertEqual(
            scheduler.barrier_releases,
            2,
        )

        self.assertEqual(
            scheduler.barrier_epoch,
            2,
        )

        self.assertEqual(
            wave0.barrier_epoch,
            2,
        )

        self.assertEqual(
            wave1.barrier_epoch,
            2,
        )

    def test_sim10_barrier_deadlock_detection(self):
        workgroup = WorkgroupState()

        wave0 = A0GPU(
            workgroup=workgroup,
            wave_id=0,
        )

        wave1 = A0GPU(
            workgroup=workgroup,
            wave_id=1,
        )

        wave0.load_program(
            assemble_source(
                """
                BARRIER
                HALT
                """
            )
        )

        wave1.load_program(
            assemble_source(
                """
                HALT
                """
            )
        )

        scheduler = WorkgroupScheduler(
            [wave0, wave1]
        )

        with self.assertRaises(
            RuntimeError
        ):
            self.run_silently(
                scheduler
            )

    def test_sim10_barrier_requires_full_exec_mask(self):
        gpu = A0GPU()

        gpu.exec_mask[-1] = False

        gpu.load_program(
            assemble_source(
                """
                BARRIER
                HALT
                """
            )
        )

        with self.assertRaises(
            RuntimeError
        ):
            self.run_silently(
                gpu
            )

    def test_sim11_fp32_encoding(self):
        words = assemble_source(
            """
            VFADD V3, V1, V2
            VFFMA V4, V1, V2, V3
            HALT
            """
        )

        add = decode(words[0])
        fma = decode(words[1])

        self.assertEqual(
            add.opcode,
            Opcode.VFADD,
        )

        self.assertEqual(
            fma.opcode,
            Opcode.VFFMA,
        )

        self.assertEqual(
            fma.src2,
            3,
        )

    def test_sim11_fp32_add_sub_mul(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = (
                f32_to_bits(1.5)
            )

            gpu.vector_regs[2][thread] = (
                f32_to_bits(2.25)
            )

            gpu.vector_regs[5][thread] = (
                f32_to_bits(4.0)
            )

        gpu.load_program(
            assemble_source(
                """
                VFADD V3, V1, V2
                VFSUB V4, V2, V1
                VFMUL V6, V1, V5
                HALT
                """
            )
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[3][thread],
                f32_to_bits(3.75),
            )

            self.assertEqual(
                gpu.vector_regs[4][thread],
                f32_to_bits(0.75),
            )

            self.assertEqual(
                gpu.vector_regs[6][thread],
                f32_to_bits(6.0),
            )

    def test_sim11_fma_is_fused(self):
        gpu = A0GPU()

        # 1 + 2^-23
        a_bits = 0x3F800001

        # 1 - 2^-23
        b_bits = 0x3F7FFFFE

        c_bits = f32_to_bits(-1.0)

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = a_bits
            gpu.vector_regs[2][thread] = b_bits
            gpu.vector_regs[3][thread] = c_bits

        gpu.load_program(
            assemble_source(
                """
                VFFMA V4, V1, V2, V3
                VFMUL V5, V1, V2
                VFADD V6, V5, V3
                HALT
                """
            )
        )

        self.run_silently(gpu)

        fused_expected = f32_to_bits(
            -(2.0 ** -46)
        )

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[4][thread],
                fused_expected,
            )

            self.assertEqual(
                gpu.vector_regs[6][thread],
                0x00000000,
            )

            self.assertNotEqual(
                gpu.vector_regs[4][thread],
                gpu.vector_regs[6][thread],
            )

    def test_sim11_predicated_fp32_execution(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = (
                f32_to_bits(float(thread))
            )

            gpu.vector_regs[2][thread] = (
                f32_to_bits(1.0)
            )

            gpu.vector_regs[3][thread] = (
                f32_to_bits(-999.0)
            )

            gpu.vector_regs[10][thread] = thread
            gpu.vector_regs[11][thread] = 16

        gpu.load_program(
            assemble_source(
                """
                VCMP_LT P0, V10, V11
                @P0 VFADD V3, V1, V2
                HALT
                """
            )
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            expected = (
                f32_to_bits(
                    float(thread) + 1.0
                )
                if thread < 16
                else f32_to_bits(-999.0)
            )

            self.assertEqual(
                gpu.vector_regs[3][thread],
                expected,
            )

    def test_sim11_fp32_special_values(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = (
                0x80000000
            )

            gpu.vector_regs[2][thread] = (
                f32_to_bits(2.0)
            )

            gpu.vector_regs[3][thread] = (
                f32_to_bits(float("inf"))
            )

            gpu.vector_regs[4][thread] = (
                f32_to_bits(float("nan"))
            )

        gpu.load_program(
            assemble_source(
                """
                VFMUL V5, V1, V2
                VFADD V6, V3, V2
                VFADD V7, V4, V2
                HALT
                """
            )
        )

        self.run_silently(gpu)

        import math

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[5][thread],
                0x80000000,
            )

            self.assertTrue(
                math.isinf(
                    f32_from_bits(
                        gpu.vector_regs[6][thread]
                    )
                )
            )

            self.assertTrue(
                math.isnan(
                    f32_from_bits(
                        gpu.vector_regs[7][thread]
                    )
                )
            )

    def test_sim11_fp32_bit_round_trip(self):
        samples = [
            0x00000000,
            0x80000000,
            0x3F800000,
            0xBF800000,
            0x7F800000,
            0xFF800000,
            0x00800000,
            0x00000001,
        ]

        for bits in samples:
            self.assertEqual(
                f32_to_bits(
                    f32_from_bits(bits)
                ),
                bits,
            )

    def test_sim12_single_wave_fp_dependency_latency(self):
        gpu = A0GPU(
            wave_id=0,
        )

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = (
                f32_to_bits(1.0)
            )

            gpu.vector_regs[2][thread] = (
                f32_to_bits(2.0)
            )

        gpu.load_program(
            assemble_source(
                """
                VFADD V3, V1, V2
                VFADD V4, V3, V2
                HALT
                """
            )
        )

        scheduler = TimingWorkgroupScheduler(
            [gpu],
            TimingConfig(
                fp_add_latency=4,
            ),
        )

        result = scheduler.run()

        self.assertEqual(
            gpu.vector_regs[4][0],
            f32_to_bits(5.0),
        )

        self.assertGreaterEqual(
            result[
                "dependency_stall_events"
            ],
            3,
        )

        self.assertGreater(
            result["cycles"],
            3,
        )

    def test_sim12_multiple_waves_hide_fp_latency(self):
        workgroup = WorkgroupState()

        waves = []

        for wave_id in range(2):
            gpu = A0GPU(
                workgroup=workgroup,
                wave_id=wave_id,
            )

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    f32_to_bits(1.0)
                )

                gpu.vector_regs[2][thread] = (
                    f32_to_bits(2.0)
                )

            gpu.load_program(
                assemble_source(
                    """
                    VFADD V3, V1, V2
                    VFADD V4, V3, V2
                    HALT
                    """
                )
            )

            waves.append(gpu)

        scheduler = TimingWorkgroupScheduler(
            waves,
            TimingConfig(
                fp_add_latency=4,
            ),
        )

        result = scheduler.run()

        self.assertGreater(
            result[
                "latency_hidden_cycles"
            ],
            0,
        )

        self.assertGreater(
            result[
                "instructions_issued"
            ],
            0,
        )

        for gpu in waves:
            self.assertEqual(
                gpu.vector_regs[4][0],
                f32_to_bits(5.0),
            )

    def test_sim12_memory_coalescing_affects_latency(self):
        def run_pattern(stride):
            gpu = A0GPU(
                wave_id=0,
            )

            gpu.scalar_regs[0] = 0

            for thread in range(WAVE_SIZE):
                address = (
                    thread * stride
                )

                gpu.vector_regs[1][thread] = (
                    address
                )

                gpu.memory[address] = (
                    f32_to_bits(1.0)
                )

            gpu.load_program(
                assemble_source(
                    """
                    VLOADX V2, S0, V1, 0
                    VFADD  V3, V2, V2
                    HALT
                    """
                )
            )

            scheduler = (
                TimingWorkgroupScheduler(
                    [gpu],
                    TimingConfig(
                        global_memory_latency=10,
                        global_memory_transaction_penalty=1,
                        fp_add_latency=2,
                    ),
                )
            )

            return scheduler.run()

        contiguous = run_pattern(1)
        stride8 = run_pattern(8)

        self.assertGreater(
            stride8["cycles"],
            contiguous["cycles"],
        )

        self.assertGreater(
            stride8[
                "dependency_stall_events"
            ],
            contiguous[
                "dependency_stall_events"
            ],
        )

    def test_sim12_latency_configuration_changes_cycles(self):
        def run_with_latency(fp_latency):
            gpu = A0GPU(
                wave_id=0,
            )

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    f32_to_bits(3.0)
                )

                gpu.vector_regs[2][thread] = (
                    f32_to_bits(4.0)
                )

            gpu.load_program(
                assemble_source(
                    """
                    VFMUL V3, V1, V2
                    VFADD V4, V3, V2
                    HALT
                    """
                )
            )

            scheduler = (
                TimingWorkgroupScheduler(
                    [gpu],
                    TimingConfig(
                        fp_mul_latency=fp_latency,
                        fp_add_latency=fp_latency,
                    ),
                )
            )

            return scheduler.run()

        fast = run_with_latency(2)
        slow = run_with_latency(8)

        self.assertGreater(
            slow["cycles"],
            fast["cycles"],
        )

        self.assertGreater(
            slow[
                "dependency_stall_events"
            ],
            fast[
                "dependency_stall_events"
            ],
        )

    def test_sim13_repeated_load_hits_l1(self):
        gpu = A0GPU(
            wave_id=0,
        )

        gpu.scalar_regs[0] = 0

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread

            gpu.memory[thread] = (
                f32_to_bits(2.0)
            )

        gpu.load_program(
            assemble_source(
                """
                VLOADX V2, S0, V1, 0
                VFADD  V4, V2, V2
                VLOADX V3, S0, V1, 0
                VFADD  V5, V3, V3
                HALT
                """
            )
        )

        scheduler = TimingWorkgroupScheduler(
            [gpu],
            TimingConfig(
                cache_line_words=16,
                l1_capacity_lines=8,
                l2_capacity_lines=32,
                l1_hit_latency=2,
                l2_hit_latency=8,
                global_memory_latency=20,
                global_memory_transaction_penalty=0,
                fp_add_latency=2,
            ),
        )

        result = scheduler.run()

        # 32 contiguous words occupy two
        # 16-word cache lines.
        self.assertEqual(
            result["dram_accesses"],
            2,
        )

        # Repeating the same load should hit
        # those same two lines in L1.
        self.assertEqual(
            result["l1_hits"],
            2,
        )

        self.assertEqual(
            len(
                scheduler.cache_access_trace
            ),
            2,
        )

        self.assertEqual(
            scheduler.cache_access_trace[0][
                "dram_accesses"
            ],
            2,
        )

        self.assertEqual(
            scheduler.cache_access_trace[1][
                "l1_hits"
            ],
            2,
        )

    def test_sim13_l2_hit_after_l1_eviction(self):
        gpu = A0GPU(
            wave_id=0,
        )

        gpu.scalar_regs[0] = 0

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread

            gpu.memory[thread] = (
                f32_to_bits(1.0)
            )

            gpu.memory[
                128 + thread
            ] = f32_to_bits(2.0)

        gpu.load_program(
            assemble_source(
                """
                VLOADX V2, S0, V1, 0
                VFADD  V4, V2, V2

                VLOADX V3, S0, V1, 128
                VFADD  V5, V3, V3

                VLOADX V6, S0, V1, 0
                VFADD  V7, V6, V6

                HALT
                """
            )
        )

        scheduler = TimingWorkgroupScheduler(
            [gpu],
            TimingConfig(
                cache_line_words=16,
                l1_capacity_lines=1,
                l2_capacity_lines=8,
                l1_hit_latency=2,
                l2_hit_latency=8,
                global_memory_latency=20,
                global_memory_transaction_penalty=0,
                fp_add_latency=2,
            ),
        )

        result = scheduler.run()

        self.assertGreater(
            result["l1_evictions"],
            0,
        )

        # The third access returns to the first
        # address range after L1 eviction.
        # L2 should still retain the lines.
        self.assertGreaterEqual(
            result["l2_hits"],
            2,
        )

        self.assertEqual(
            scheduler.cache_access_trace[2][
                "l2_hits"
            ],
            2,
        )

    def test_sim13_cache_hit_reduces_cycles(self):
        def run(second_immediate):
            gpu = A0GPU(
                wave_id=0,
            )

            gpu.scalar_regs[0] = 0

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    thread
                )

                gpu.memory[thread] = (
                    f32_to_bits(1.0)
                )

                gpu.memory[
                    512 + thread
                ] = f32_to_bits(1.0)

            gpu.load_program(
                assemble_source(
                    f"""
                    VLOADX V2, S0, V1, 0
                    VFADD  V4, V2, V2

                    VLOADX V3, S0, V1, {second_immediate}
                    VFADD  V5, V3, V3

                    HALT
                    """
                )
            )

            scheduler = (
                TimingWorkgroupScheduler(
                    [gpu],
                    TimingConfig(
                        cache_line_words=16,
                        l1_capacity_lines=8,
                        l2_capacity_lines=32,
                        l1_hit_latency=2,
                        l2_hit_latency=8,
                        global_memory_latency=20,
                        global_memory_transaction_penalty=0,
                        fp_add_latency=2,
                    ),
                )
            )

            return scheduler.run()

        warm = run(0)
        cold = run(512)

        self.assertGreater(
            warm["l1_hits"],
            0,
        )

        self.assertGreater(
            cold["dram_accesses"],
            warm["dram_accesses"],
        )

        self.assertLess(
            warm["cycles"],
            cold["cycles"],
        )

    def test_sim13_cache_line_geometry_is_configurable(self):
        def run(line_words):
            gpu = A0GPU(
                wave_id=0,
            )

            gpu.scalar_regs[0] = 0

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    thread
                )

                gpu.memory[thread] = thread

            gpu.load_program(
                assemble_source(
                    """
                    VLOADX V2, S0, V1, 0
                    HALT
                    """
                )
            )

            scheduler = (
                TimingWorkgroupScheduler(
                    [gpu],
                    TimingConfig(
                        cache_line_words=line_words,
                        l1_capacity_lines=16,
                        l2_capacity_lines=64,
                        global_memory_transaction_penalty=0,
                    ),
                )
            )

            return scheduler.run()

        line8 = run(8)
        line16 = run(16)

        # 32 contiguous words:
        # 8-word lines  -> 4 lines
        # 16-word lines -> 2 lines
        self.assertEqual(
            line8["dram_accesses"],
            4,
        )

        self.assertEqual(
            line16["dram_accesses"],
            2,
        )

    def test_sim14_vector_register_pressure_limits_occupancy(self):
        config = OccupancyConfig(
            vector_register_words=4096,
            scalar_registers=4096,
            shared_memory_words=4096,
            max_resident_waves=8,
            max_resident_workgroups=8,
        )

        low = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=2,
                vector_registers_per_lane=16,
                scalar_registers_per_wave=4,
            ),
        )

        high = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=2,
                vector_registers_per_lane=64,
                scalar_registers_per_wave=4,
            ),
        )

        self.assertEqual(
            low["resident_waves"],
            8,
        )

        self.assertEqual(
            high["resident_waves"],
            2,
        )

        self.assertIn(
            "vector_registers",
            high["limiting_resources"],
        )

        self.assertGreater(
            low["occupancy"],
            high["occupancy"],
        )

    def test_sim14_scalar_register_pressure_limits_occupancy(self):
        config = OccupancyConfig(
            vector_register_words=65536,
            scalar_registers=64,
            shared_memory_words=4096,
            max_resident_waves=8,
            max_resident_workgroups=8,
        )

        result = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=2,
                vector_registers_per_lane=4,
                scalar_registers_per_wave=16,
            ),
        )

        self.assertEqual(
            result["resident_workgroups"],
            2,
        )

        self.assertEqual(
            result["resident_waves"],
            4,
        )

        self.assertIn(
            "scalar_registers",
            result["limiting_resources"],
        )

    def test_sim14_lds_pressure_limits_occupancy(self):
        config = OccupancyConfig(
            vector_register_words=65536,
            scalar_registers=4096,
            shared_memory_words=512,
            max_resident_waves=8,
            max_resident_workgroups=8,
        )

        result = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=2,
                vector_registers_per_lane=4,
                scalar_registers_per_wave=4,
                shared_words_per_workgroup=256,
            ),
        )

        self.assertEqual(
            result["resident_workgroups"],
            2,
        )

        self.assertEqual(
            result["resident_waves"],
            4,
        )

        self.assertIn(
            "shared_memory",
            result["limiting_resources"],
        )

    def test_sim14_residency_uses_whole_workgroups(self):
        config = OccupancyConfig(
            vector_register_words=65536,
            scalar_registers=4096,
            shared_memory_words=4096,
            max_resident_waves=7,
            max_resident_workgroups=8,
        )

        result = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=3,
                vector_registers_per_lane=4,
                scalar_registers_per_wave=4,
            ),
        )

        # Seven wave slots cannot host 7 waves when
        # workgroups contain exactly three waves.
        # Only two complete workgroups fit.
        self.assertEqual(
            result["resident_workgroups"],
            2,
        )

        self.assertEqual(
            result["resident_waves"],
            6,
        )

        self.assertIn(
            "wave_slots",
            result["limiting_resources"],
        )

    def test_sim14_occupancy_changes_latency_hiding_throughput(self):
        config = OccupancyConfig(
            vector_register_words=4096,
            scalar_registers=4096,
            shared_memory_words=4096,
            max_resident_waves=4,
            max_resident_workgroups=4,
        )

        low_pressure = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=1,
                vector_registers_per_lane=16,
                scalar_registers_per_wave=4,
            ),
        )

        high_pressure = calculate_occupancy(
            config,
            KernelResourceUsage(
                waves_per_workgroup=1,
                vector_registers_per_lane=64,
                scalar_registers_per_wave=4,
            ),
        )

        program = assemble_source(
            """
            VFADD V3, V1, V2
            VFADD V4, V3, V2
            HALT
            """
        )

        def initialize(wave, wave_id):
            for thread in range(WAVE_SIZE):
                wave.vector_regs[1][thread] = (
                    f32_to_bits(1.0)
                )

                wave.vector_regs[2][thread] = (
                    f32_to_bits(2.0)
                )

        timing = TimingConfig(
            fp_add_latency=4,
        )

        low_result = (
            run_resident_wave_timing_experiment(
                program,
                low_pressure,
                timing_config=timing,
                initialize_wave=initialize,
            )
        )

        high_result = (
            run_resident_wave_timing_experiment(
                program,
                high_pressure,
                timing_config=timing,
                initialize_wave=initialize,
            )
        )

        self.assertEqual(
            low_result["resident_waves"],
            4,
        )

        self.assertEqual(
            high_result["resident_waves"],
            2,
        )

        self.assertGreater(
            low_result[
                "latency_hidden_cycles"
            ],
            high_result[
                "latency_hidden_cycles"
            ],
        )

        self.assertGreater(
            low_result["waves_per_cycle"],
            high_result["waves_per_cycle"],
        )

        self.assertLess(
            low_result["cycles_per_wave"],
            high_result["cycles_per_wave"],
        )

    def test_vector_bitwise_execution(self):
        gpu = A0GPU()

        a = 0xF0F0AA55
        b = 0x0FF00FF0

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = a
            gpu.vector_regs[2][thread] = b

        gpu.load_program(
            assemble_source(
                """
                VAND V3, V1, V2
                VOR  V4, V1, V2
                VXOR V5, V1, V2
                HALT
                """
            )
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.vector_regs[3][thread],
                (a & b) & 0xFFFFFFFF,
            )

            self.assertEqual(
                gpu.vector_regs[4][thread],
                (a | b) & 0xFFFFFFFF,
            )

            self.assertEqual(
                gpu.vector_regs[5][thread],
                (a ^ b) & 0xFFFFFFFF,
            )

    def test_vector_compare_execution(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = thread
            gpu.vector_regs[2][thread] = 16

        gpu.load_program(
            assemble_source(
                """
                VCMP_EQ P0, V1, V2
                VCMP_LT P1, V1, V2
                VCMP_LE P2, V1, V2
                HALT
                """
            )
        )

        self.run_silently(gpu)

        for thread in range(WAVE_SIZE):
            self.assertEqual(
                gpu.predicate_regs[0][thread],
                thread == 16,
            )

            self.assertEqual(
                gpu.predicate_regs[1][thread],
                thread < 16,
            )

            self.assertEqual(
                gpu.predicate_regs[2][thread],
                thread <= 16,
            )

    def test_sim15_scheduler_policy_validation(self):
        with self.assertRaises(ValueError):
            TimingConfig(
                scheduler_policy="not-a-policy",
            )

        with self.assertRaises(ValueError):
            TimingConfig(
                vector_frontend_model="not-a-model",
            )

    def test_sim15_lrr_and_gto_have_distinct_issue_order(self):
        def run(policy):
            workgroup = WorkgroupState()
            waves = []

            for wave_id in range(2):
                gpu = A0GPU(
                    workgroup=workgroup,
                    wave_id=wave_id,
                )

                for thread in range(WAVE_SIZE):
                    gpu.vector_regs[1][thread] = 1
                    gpu.vector_regs[2][thread] = 2

                gpu.load_program(
                    assemble_source(
                        """
                        VADD V3, V1, V2
                        VADD V4, V1, V2
                        HALT
                        """
                    )
                )

                waves.append(gpu)

            scheduler = TimingWorkgroupScheduler(
                waves,
                TimingConfig(
                    scheduler_policy=policy,
                ),
            )

            with redirect_stdout(io.StringIO()):
                scheduler.run()

            return [
                entry["wave_id"]
                for entry in scheduler.issue_trace
            ]

        self.assertEqual(
            run("lrr")[:4],
            [0, 1, 0, 1],
        )

        self.assertEqual(
            run("gto")[:4],
            [0, 0, 0, 1],
        )

    def test_sim15_a0_adaptive_preserves_memory_streak(self):
        workgroup = WorkgroupState()
        waves = []

        for wave_id in range(2):
            gpu = A0GPU(
                workgroup=workgroup,
                wave_id=wave_id,
            )

            gpu.scalar_regs[0] = wave_id * 128

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = thread
                gpu.memory[
                    wave_id * 128 + thread
                ] = thread

            gpu.load_program(
                assemble_source(
                    """
                    VLOADX V8, S0, V1, 0
                    VLOADX V9, S0, V1, 0
                    VADD   V10, V1, V2
                    HALT
                    """
                )
            )

            waves.append(gpu)

        scheduler = TimingWorkgroupScheduler(
            waves,
            TimingConfig(
                scheduler_policy="a0_adaptive_v0",
                l2_capacity_lines=2,
            ),
        )

        with redirect_stdout(io.StringIO()):
            scheduler.run()

        trace = [
            (
                entry["wave_id"],
                entry["opcode"],
            )
            for entry in scheduler.issue_trace
        ]

        self.assertEqual(
            trace[:2],
            [
                (0, "VLOADX"),
                (0, "VLOADX"),
            ],
        )

        self.assertEqual(
            trace[2][0],
            1,
        )

    def test_sim15_rtl6b_vrf_conflict_penalty(self):
        def run(src1):
            gpu = A0GPU()

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = 1
                gpu.vector_regs[2][thread] = 2
                gpu.vector_regs[5][thread] = 5

            gpu.load_program(
                assemble_source(
                    f"""
                    VADD V8, V1, V{src1}
                    HALT
                    """
                )
            )

            scheduler = TimingWorkgroupScheduler(
                [gpu],
                TimingConfig(
                    vector_frontend_model=(
                        "rtl6b_coarse"
                    ),
                ),
            )

            with redirect_stdout(io.StringIO()):
                return scheduler.run()

        no_conflict = run(2)
        conflict = run(5)

        self.assertEqual(
            no_conflict[
                "vrf_conflict_penalty_cycles"
            ],
            0,
        )

        self.assertEqual(
            conflict[
                "vrf_conflict_penalty_cycles"
            ],
            4,
        )

        self.assertEqual(
            conflict[
                "vrf_bank_conflict_instructions"
            ],
            1,
        )

        self.assertGreater(
            conflict["cycles"],
            no_conflict["cycles"],
        )

    def test_sim15_default_frontend_remains_ideal(self):
        gpu = A0GPU()

        for thread in range(WAVE_SIZE):
            gpu.vector_regs[1][thread] = 1
            gpu.vector_regs[5][thread] = 5

        gpu.load_program(
            assemble_source(
                """
                VADD V8, V1, V5
                HALT
                """
            )
        )

        scheduler = TimingWorkgroupScheduler(
            [gpu],
            TimingConfig(),
        )

        with redirect_stdout(io.StringIO()):
            result = scheduler.run()

        self.assertEqual(
            result["vector_frontend_model"],
            "ideal",
        )

        self.assertEqual(
            result["frontend_stall_events"],
            0,
        )

    def test_sim15_scheduler_policies_preserve_architecture(self):
        fingerprints = []

        for policy in (
            "lrr",
            "gto",
            "oldest_ready",
            "a0_adaptive_v0",
        ):
            workgroup = WorkgroupState()
            waves = []

            for wave_id in range(4):
                gpu = A0GPU(
                    workgroup=workgroup,
                    wave_id=wave_id,
                )

                for thread in range(WAVE_SIZE):
                    gpu.vector_regs[1][thread] = (
                        thread + wave_id
                    )
                    gpu.vector_regs[2][thread] = 3

                gpu.load_program(
                    assemble_source(
                        """
                        VADD V3, V1, V2
                        VMUL V4, V3, V2
                        HALT
                        """
                    )
                )

                waves.append(gpu)

            scheduler = TimingWorkgroupScheduler(
                waves,
                TimingConfig(
                    scheduler_policy=policy,
                    vector_frontend_model=(
                        "rtl6b_coarse"
                    ),
                ),
            )

            with redirect_stdout(io.StringIO()):
                scheduler.run()

            fingerprints.append(
                tuple(
                    tuple(gpu.vector_regs[4])
                    for gpu in waves
                )
            )

        self.assertTrue(
            all(
                fingerprint == fingerprints[0]
                for fingerprint in fingerprints[1:]
            )
        )

    def test_structured_control_opcodes(self):
        source = """
            SPLIT P0
            ELSE
            JOIN
            HALT
        """

        words = assemble_source(source)

        opcodes = [
            decode(word).opcode
            for word in words
        ]

        self.assertEqual(
            opcodes,
            [
                Opcode.SPLIT,
                Opcode.ELSE,
                Opcode.JOIN,
                Opcode.HALT,
            ],
        )


if __name__ == "__main__":
    unittest.main()