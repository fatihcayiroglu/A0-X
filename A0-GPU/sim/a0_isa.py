from dataclasses import dataclass
from enum import IntEnum


class Opcode(IntEnum):
    NOP = 0x00

    VADD = 0x01
    VSUB = 0x02
    VMUL = 0x03
    VAND = 0x04
    VOR = 0x05
    VXOR = 0x06

    FADD = 0x20
    FSUB = 0x21
    FMUL = 0x22
    FFMA = 0x23
    VFADD = FADD
    VFSUB = FSUB
    VFMUL = FMUL
    VFFMA = FFMA

    SADD = 0x40
    SSUB = 0x41

    VLOAD = 0x50
    VSTORE = 0x51
    SLOAD = 0x52
    SSTORE = 0x53
    VLOADX = 0x54
    VSTOREX = 0x55
    LDSLOAD = 0x56
    LDSSTORE = 0x57

    VCMP_EQ = 0x60
    VCMP_LT = 0x61
    VCMP_LE = 0x62
    SCMP_LT = 0x63

    JMP = 0x70
    BRA = 0x71
    SPLIT = 0x72
    ELSE = 0x73
    JOIN = 0x74
    BARRIER = 0x75

    HALT = 0xFF


@dataclass(frozen=True)
class Instruction:
    opcode: Opcode
    flags: int = 0
    dst: int = 0
    src0: int = 0
    src1: int = 0
    src2: int = 0
    pred: int = 0
    imm24: int = 0


def _check_range(name, value, bits):
    maximum = (1 << bits) - 1

    if not 0 <= value <= maximum:
        raise ValueError(
            f"{name}={value} does not fit in {bits} bits"
        )


def encode(instr: Instruction) -> int:
    _check_range("opcode", int(instr.opcode), 8)
    _check_range("flags", instr.flags, 4)
    _check_range("dst", instr.dst, 6)
    _check_range("src0", instr.src0, 6)
    _check_range("src1", instr.src1, 6)
    _check_range("src2", instr.src2, 6)
    _check_range("pred", instr.pred, 4)
    _check_range("imm24", instr.imm24, 24)

    word = 0

    word |= int(instr.opcode) << 56
    word |= instr.flags << 52
    word |= instr.dst << 46
    word |= instr.src0 << 40
    word |= instr.src1 << 34
    word |= instr.src2 << 28
    word |= instr.pred << 24
    word |= instr.imm24

    return word


def decode(word: int) -> Instruction:
    if not 0 <= word <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("Instruction must be 64 bits")

    return Instruction(
        opcode=Opcode((word >> 56) & 0xFF),
        flags=(word >> 52) & 0xF,
        dst=(word >> 46) & 0x3F,
        src0=(word >> 40) & 0x3F,
        src1=(word >> 34) & 0x3F,
        src2=(word >> 28) & 0x3F,
        pred=(word >> 24) & 0xF,
        imm24=word & 0xFFFFFF,
    )


def main():
    instruction = Instruction(
        opcode=Opcode.VADD,
        dst=3,
        src0=1,
        src1=2,
    )

    encoded = encode(instruction)
    decoded = decode(encoded)

    print("Original:")
    print(instruction)

    print()

    print("Binary:")
    print(f"{encoded:064b}")

    print()

    print("Hex:")
    print(f"0x{encoded:016X}")

    print()

    print("Decoded:")
    print(decoded)

    print()

    if decoded == instruction:
        print("A0 ISA encode/decode: PASS")
    else:
        print("A0 ISA encode/decode: FAIL")
        raise SystemExit(1)


if __name__ == "__main__":
    main()