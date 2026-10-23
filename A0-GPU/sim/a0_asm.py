import re

from a0_isa import Instruction, Opcode, encode


VECTOR_REGISTER_RE = re.compile(r"^V([0-9]+)$", re.IGNORECASE)
PREDICATE_REGISTER_RE = re.compile(r"^P([0-9]+)$", re.IGNORECASE)
SCALAR_REGISTER_RE = re.compile(r"^S([0-9]+)$", re.IGNORECASE)
SCALAR_PREDICATE_REGISTER_RE = re.compile(r"^Q([0-9]+)$", re.IGNORECASE)
LABEL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

FLAG_PREDICATED = 0x1


def parse_vector_register(token: str) -> int:
    token = token.strip()

    match = VECTOR_REGISTER_RE.match(token)

    if not match:
        raise ValueError(f"Invalid vector register: {token}")

    register = int(match.group(1))

    if not 0 <= register <= 63:
        raise ValueError(f"Vector register out of range: V{register}")

    return register


def parse_scalar_register(token: str) -> int:
    token = token.strip()

    match = SCALAR_REGISTER_RE.match(token)

    if not match:
        raise ValueError(f"Invalid scalar register: {token}")

    register = int(match.group(1))

    if not 0 <= register <= 31:
        raise ValueError(
            f"Scalar register out of range: S{register}"
        )

    return register


def parse_scalar_predicate_register(token: str) -> int:
    token = token.strip()

    match = SCALAR_PREDICATE_REGISTER_RE.match(token)

    if not match:
        raise ValueError(
            f"Invalid scalar predicate register: {token}"
        )

    register = int(match.group(1))

    if not 0 <= register <= 15:
        raise ValueError(
            f"Scalar predicate out of range: Q{register}"
        )

    return register


def parse_predicate_register(token: str) -> int:
    token = token.strip()

    if token.startswith("@"):
        token = token[1:]

    match = PREDICATE_REGISTER_RE.match(token)

    if not match:
        raise ValueError(f"Invalid predicate register: {token}")

    register = int(match.group(1))

    if not 0 <= register <= 15:
        raise ValueError(f"Predicate register out of range: P{register}")

    return register


def clean_line(line: str) -> str:
    line = line.split("#", 1)[0]
    line = line.split(";", 1)[0]

    return line.strip()


def parse_instruction(
    line: str,
    *,
    pc: int = 0,
    labels=None,
) -> Instruction:
    line = clean_line(line)

    if not line:
        raise ValueError("Empty instruction")

    if labels is None:
        labels = {}

    parts = line.replace(",", " ").split()

    predicated = False
    predicate = 0

    if parts[0].startswith("@"):
        predicate = parse_predicate_register(parts[0])
        predicated = True
        parts = parts[1:]

    if not parts:
        raise ValueError("Missing instruction")

    mnemonic = parts[0].upper()
    operands = parts[1:]

    flags = FLAG_PREDICATED if predicated else 0

    if mnemonic in {"VADD", "VSUB", "VMUL", "VAND", "VOR", "VXOR"}:
        if len(operands) != 3:
            raise ValueError(
                f"{mnemonic} requires: dst, src0, src1"
            )

        return Instruction(
            opcode=Opcode[mnemonic],
            flags=flags,
            dst=parse_vector_register(operands[0]),
            src0=parse_vector_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            pred=predicate,
        )

    if mnemonic in {
        "VCMP_EQ",
        "VCMP_LT",
        "VCMP_LE",
    }:
        if predicated:
            raise ValueError("VCMP_LT cannot itself be predicated in SIM2")

        if len(operands) != 3:
            raise ValueError(
                f"{mnemonic} requires: predicate_dst, src0, src1"
            )

        return Instruction(
            opcode=Opcode[mnemonic],
            src0=parse_vector_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            pred=parse_predicate_register(operands[0]),
        )

    if mnemonic == "LDSLOAD":
        if len(operands) != 3:
            raise ValueError(
                "LDSLOAD requires: dst, vector_address, immediate"
            )

        immediate = int(operands[2], 0)

        if not -(1 << 23) <= immediate <= (1 << 23) - 1:
            raise ValueError(
                "LDSLOAD immediate must fit signed IMM24"
            )

        return Instruction(
            opcode=Opcode.LDSLOAD,
            flags=flags,
            dst=parse_vector_register(operands[0]),
            src0=parse_vector_register(operands[1]),
            pred=predicate,
            imm24=immediate & 0xFFFFFF,
        )

    if mnemonic == "LDSSTORE":
        if len(operands) != 3:
            raise ValueError(
                "LDSSTORE requires: src, vector_address, immediate"
            )

        immediate = int(operands[2], 0)

        if not -(1 << 23) <= immediate <= (1 << 23) - 1:
            raise ValueError(
                "LDSSTORE immediate must fit signed IMM24"
            )

        return Instruction(
            opcode=Opcode.LDSSTORE,
            flags=flags,
            src0=parse_vector_register(operands[1]),
            src1=parse_vector_register(operands[0]),
            pred=predicate,
            imm24=immediate & 0xFFFFFF,
        )

    if mnemonic == "VLOADX":
        if len(operands) != 4:
            raise ValueError(
                "VLOADX requires: dst, scalar_base, vector_offset, immediate"
            )

        immediate = int(operands[3], 0)

        if not -(1 << 23) <= immediate <= (1 << 23) - 1:
            raise ValueError(
                "VLOADX immediate must fit signed IMM24"
            )

        return Instruction(
            opcode=Opcode.VLOADX,
            flags=flags,
            dst=parse_vector_register(operands[0]),
            src0=parse_scalar_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            pred=predicate,
            imm24=immediate & 0xFFFFFF,
        )

    if mnemonic == "VSTOREX":
        if len(operands) != 4:
            raise ValueError(
                "VSTOREX requires: src, scalar_base, vector_offset, immediate"
            )

        immediate = int(operands[3], 0)

        if not -(1 << 23) <= immediate <= (1 << 23) - 1:
            raise ValueError(
                "VSTOREX immediate must fit signed IMM24"
            )

        return Instruction(
            opcode=Opcode.VSTOREX,
            flags=flags,
            src0=parse_scalar_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            src2=parse_vector_register(operands[0]),
            pred=predicate,
            imm24=immediate & 0xFFFFFF,
        )

    if mnemonic == "VLOAD":
        if len(operands) != 2:
            raise ValueError("VLOAD requires: dst, address")

        address = int(operands[1], 0)

        if not 0 <= address <= 0xFFFFFF:
            raise ValueError(
                "VLOAD address must fit in IMM24"
            )

        return Instruction(
            opcode=Opcode.VLOAD,
            flags=flags,
            dst=parse_vector_register(operands[0]),
            pred=predicate,
            imm24=address,
        )

    if mnemonic == "SLOAD":
        if predicated:
            raise ValueError(
                "SLOAD cannot use vector predicate syntax"
            )

        if len(operands) != 2:
            raise ValueError(
                "SLOAD requires: dst, address"
            )

        address = int(operands[1], 0)

        if not 0 <= address <= 0xFFFFFF:
            raise ValueError(
                "SLOAD address must fit in IMM24"
            )

        return Instruction(
            opcode=Opcode.SLOAD,
            dst=parse_scalar_register(operands[0]),
            imm24=address,
        )

    if mnemonic == "SSTORE":
        if predicated:
            raise ValueError(
                "SSTORE cannot use vector predicate syntax"
            )

        if len(operands) != 2:
            raise ValueError(
                "SSTORE requires: src, address"
            )

        address = int(operands[1], 0)

        if not 0 <= address <= 0xFFFFFF:
            raise ValueError(
                "SSTORE address must fit in IMM24"
            )

        return Instruction(
            opcode=Opcode.SSTORE,
            src0=parse_scalar_register(operands[0]),
            imm24=address,
        )

    if mnemonic == "VSTORE":
        if len(operands) != 2:
            raise ValueError("VSTORE requires: src, address")

        address = int(operands[1], 0)

        if not 0 <= address <= 0xFFFFFF:
            raise ValueError("VSTORE address must fit in IMM24")

        return Instruction(
            opcode=Opcode.VSTORE,
            flags=flags,
            src0=parse_vector_register(operands[0]),
            pred=predicate,
            imm24=address,
        )

    if mnemonic in {"VFADD", "VFSUB", "VFMUL"}:
        if len(operands) != 3:
            raise ValueError(
                f"{mnemonic} requires: dst, src0, src1"
            )

        return Instruction(
            opcode=Opcode[mnemonic],
            flags=flags,
            dst=parse_vector_register(operands[0]),
            src0=parse_vector_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            pred=predicate,
        )

    if mnemonic == "VFFMA":
        if len(operands) != 4:
            raise ValueError(
                "VFFMA requires: dst, src0, src1, src2"
            )

        return Instruction(
            opcode=Opcode.VFFMA,
            flags=flags,
            dst=parse_vector_register(operands[0]),
            src0=parse_vector_register(operands[1]),
            src1=parse_vector_register(operands[2]),
            src2=parse_vector_register(operands[3]),
            pred=predicate,
        )

    if mnemonic in {"SADD", "SSUB"}:
        if predicated:
            raise ValueError(
                f"{mnemonic} cannot use vector predicate syntax"
            )

        if len(operands) != 3:
            raise ValueError(
                f"{mnemonic} requires: dst, src0, src1"
            )

        return Instruction(
            opcode=Opcode[mnemonic],
            dst=parse_scalar_register(operands[0]),
            src0=parse_scalar_register(operands[1]),
            src1=parse_scalar_register(operands[2]),
        )

    if mnemonic == "SCMP_LT":
        if predicated:
            raise ValueError(
                "SCMP_LT cannot use vector predicate syntax"
            )

        if len(operands) != 3:
            raise ValueError(
                "SCMP_LT requires: qdst, src0, src1"
            )

        return Instruction(
            opcode=Opcode.SCMP_LT,
            src0=parse_scalar_register(operands[1]),
            src1=parse_scalar_register(operands[2]),
            pred=parse_scalar_predicate_register(
                operands[0]
            ),
        )

    if mnemonic == "BRA":
        if predicated:
            raise ValueError(
                "BRA cannot use @predicate syntax"
            )

        if len(operands) != 2:
            raise ValueError(
                "BRA requires: scalar_predicate, target"
            )

        scalar_predicate = (
            parse_scalar_predicate_register(
                operands[0]
            )
        )

        target = operands[1]

        if target in labels:
            offset = labels[target] - (pc + 1)
        else:
            try:
                offset = int(target, 0)
            except ValueError as exc:
                raise ValueError(
                    f"Unknown label: {target}"
                ) from exc

        if not -(1 << 23) <= offset <= (1 << 23) - 1:
            raise ValueError(
                f"BRA offset out of signed IMM24 range: "
                f"{offset}"
            )

        return Instruction(
            opcode=Opcode.BRA,
            pred=scalar_predicate,
            imm24=offset & 0xFFFFFF,
        )

    if mnemonic == "JMP":
        if predicated:
            raise ValueError("JMP cannot be predicated")

        if len(operands) != 1:
            raise ValueError("JMP requires: target")

        target = operands[0]

        if target in labels:
            offset = labels[target] - (pc + 1)
        else:
            try:
                offset = int(target, 0)
            except ValueError as exc:
                raise ValueError(
                    f"Unknown label: {target}"
                ) from exc

        if not -(1 << 23) <= offset <= (1 << 23) - 1:
            raise ValueError(
                f"JMP offset out of signed IMM24 range: {offset}"
            )

        return Instruction(
            opcode=Opcode.JMP,
            imm24=offset & 0xFFFFFF,
        )

    if mnemonic == "BARRIER":
        if predicated:
            raise ValueError(
                "BARRIER cannot be predicated"
            )

        if operands:
            raise ValueError(
                "BARRIER takes no operands"
            )

        return Instruction(
            opcode=Opcode.BARRIER,
        )

    if mnemonic == "SPLIT":
        if predicated:
            raise ValueError("SPLIT cannot use @predicate syntax")

        if len(operands) != 1:
            raise ValueError("SPLIT requires: predicate")

        return Instruction(
            opcode=Opcode.SPLIT,
            pred=parse_predicate_register(operands[0]),
        )

    if mnemonic == "ELSE":
        if predicated:
            raise ValueError("ELSE cannot be predicated")

        if operands:
            raise ValueError("ELSE takes no operands")

        return Instruction(
            opcode=Opcode.ELSE,
        )

    if mnemonic == "JOIN":
        if predicated:
            raise ValueError("JOIN cannot be predicated")

        if operands:
            raise ValueError("JOIN takes no operands")

        return Instruction(
            opcode=Opcode.JOIN,
        )

    if mnemonic == "HALT":
        if predicated:
            raise ValueError("HALT cannot be predicated")

        if operands:
            raise ValueError("HALT takes no operands")

        return Instruction(
            opcode=Opcode.HALT,
        )

    raise ValueError(f"Unknown instruction: {mnemonic}")


def assemble_source(source: str) -> list[int]:
    labels = {}
    instructions = []

    # PASS 1:
    # Find label addresses and instruction PCs.
    pc = 0

    for line_number, source_line in enumerate(
        source.splitlines(),
        start=1,
    ):
        line = clean_line(source_line)

        if not line:
            continue

        if ":" in line:
            if line.count(":") != 1:
                raise ValueError(
                    f"Line {line_number}: invalid label syntax"
                )

            label, remainder = line.split(":", 1)
            label = label.strip()

            if not LABEL_RE.fullmatch(label):
                raise ValueError(
                    f"Line {line_number}: invalid label: {label}"
                )

            if label in labels:
                raise ValueError(
                    f"Line {line_number}: duplicate label: {label}"
                )

            labels[label] = pc
            line = remainder.strip()

            # A line may contain only a label.
            if not line:
                continue

        instructions.append(
            (
                line_number,
                source_line,
                line,
                pc,
            )
        )

        pc += 1

    # PASS 2:
    # Resolve labels and encode instructions.
    machine_code = []

    for (
        line_number,
        source_line,
        line,
        instruction_pc,
    ) in instructions:
        try:
            instruction = parse_instruction(
                line,
                pc=instruction_pc,
                labels=labels,
            )

            machine_code.append(
                encode(instruction)
            )

        except Exception as exc:
            raise ValueError(
                f"Line {line_number}: {exc}\n"
                f"    {source_line}"
            ) from exc

    return machine_code


def main():
    source = """
        VCMP_LT P0, V1, V2
        @P0 VADD V3, V3, V4
        VSTORE V3, 0
        HALT
    """

    machine_code = assemble_source(source)

    print("A0 Assembler SIM2")
    print()

    for pc, word in enumerate(machine_code):
        print(
            f"{pc:04d}: "
            f"0x{word:016X} "
            f"{word:064b}"
        )

    print()
    print(f"Instructions: {len(machine_code)}")
    print("A0 assembler predicate support: PASS")


if __name__ == "__main__":
    main()