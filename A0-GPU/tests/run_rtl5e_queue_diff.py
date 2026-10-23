#!/usr/bin/env python3

from dataclasses import asdict
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"
if str(SIM) not in sys.path:
    sys.path.insert(0, str(SIM))

from a0_isa import Instruction, Opcode  # noqa: E402
from a0_queue_model import (  # noqa: E402
    A0QueueModel,
    QueuePayload,
    classifier_contract,
)

RTL = ROOT / "rtl/core/a0_issue_queue.sv"
DEPTH = 8
SEED = 0xA05E
RANDOM_INSTRUCTIONS = 10_000

TRACKED_OPCODES = [
    Opcode.VADD,
    Opcode.VSUB,
    Opcode.VMUL,
    Opcode.VAND,
    Opcode.VOR,
    Opcode.VXOR,
    Opcode.VLOADX,
    Opcode.VSTOREX,
    Opcode.VCMP_EQ,
    Opcode.VCMP_LT,
    Opcode.VCMP_LE,
    Opcode.SPLIT,
]


def run(command, cwd):
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            "command failed with exit code "
            f"{result.returncode}: {' '.join(map(str, command))}"
        )
    return result.stdout


def sparse_mask(rng: random.Random, width: int, probability: float) -> int:
    value = 0
    for bit in range(width):
        if rng.random() < probability:
            value |= 1 << bit
    return value


def random_instruction(rng: random.Random) -> Instruction:
    opcode = rng.choice(TRACKED_OPCODES)
    flags = 0
    if opcode in {
        Opcode.VADD,
        Opcode.VSUB,
        Opcode.VMUL,
        Opcode.VAND,
        Opcode.VOR,
        Opcode.VXOR,
        Opcode.VLOADX,
        Opcode.VSTOREX,
    }:
        flags = rng.randrange(2)

    return Instruction(
        opcode=opcode,
        flags=flags,
        dst=rng.randrange(64),
        src0=rng.randrange(64),
        src1=rng.randrange(64),
        src2=rng.randrange(64),
        pred=rng.randrange(16),
    )


def payload_tuple(payload):
    if payload is None:
        return (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0,
        )
    instr = payload.instruction
    deps = payload.deps
    return (
        payload.pc,
        int(instr.opcode),
        instr.flags,
        instr.dst,
        instr.src0,
        instr.src1,
        instr.src2,
        instr.pred,
        int(deps.vector_src0_enable),
        int(deps.vector_src1_enable),
        int(deps.vector_src2_enable),
        int(deps.vector_dst_enable),
        int(deps.predicate_src_enable),
        int(deps.predicate_dst_enable),
    )


def make_temp_tb(path: Path):
    path.write_text(r'''module a0_issue_queue_diff_tb;
    logic clk;
    logic rst;

    logic dispatch_valid;
    logic [31:0] dispatch_pc;
    logic [7:0] dispatch_opcode;
    logic [3:0] dispatch_flags;
    logic [5:0] dispatch_dst;
    logic [5:0] dispatch_src0;
    logic [5:0] dispatch_src1;
    logic [5:0] dispatch_src2;
    logic [3:0] dispatch_pred;
    logic dispatch_vector_src0_enable;
    logic dispatch_vector_src1_enable;
    logic dispatch_vector_src2_enable;
    logic dispatch_vector_dst_enable;
    logic dispatch_predicate_src_enable;
    logic dispatch_predicate_dst_enable;
    logic dispatch_ready;

    logic issue_valid;
    logic [31:0] issue_pc;
    logic [7:0] issue_opcode;
    logic [3:0] issue_flags;
    logic [5:0] issue_dst;
    logic [5:0] issue_src0;
    logic [5:0] issue_src1;
    logic [5:0] issue_src2;
    logic [3:0] issue_pred;
    logic issue_vector_src0_enable;
    logic issue_vector_src1_enable;
    logic issue_vector_src2_enable;
    logic issue_vector_dst_enable;
    logic issue_predicate_src_enable;
    logic issue_predicate_dst_enable;
    logic issue_ready;

    logic [63:0] busy_vector_regs;
    logic [15:0] busy_predicate_regs;

    integer stim_file;
    integer out_file;
    integer scan_result;
    integer cycle;
    string stim_path;
    string out_path;

    a0_issue_queue #(.DEPTH(8)) dut (
        .clk(clk), .rst(rst),
        .dispatch_valid(dispatch_valid),
        .dispatch_pc(dispatch_pc),
        .dispatch_opcode(dispatch_opcode),
        .dispatch_flags(dispatch_flags),
        .dispatch_dst(dispatch_dst),
        .dispatch_src0(dispatch_src0),
        .dispatch_src1(dispatch_src1),
        .dispatch_src2(dispatch_src2),
        .dispatch_pred(dispatch_pred),
        .dispatch_vector_src0_enable(dispatch_vector_src0_enable),
        .dispatch_vector_src1_enable(dispatch_vector_src1_enable),
        .dispatch_vector_src2_enable(dispatch_vector_src2_enable),
        .dispatch_vector_dst_enable(dispatch_vector_dst_enable),
        .dispatch_predicate_src_enable(dispatch_predicate_src_enable),
        .dispatch_predicate_dst_enable(dispatch_predicate_dst_enable),
        .dispatch_ready(dispatch_ready),
        .issue_valid(issue_valid),
        .issue_pc(issue_pc),
        .issue_opcode(issue_opcode),
        .issue_flags(issue_flags),
        .issue_dst(issue_dst),
        .issue_src0(issue_src0),
        .issue_src1(issue_src1),
        .issue_src2(issue_src2),
        .issue_pred(issue_pred),
        .issue_vector_src0_enable(issue_vector_src0_enable),
        .issue_vector_src1_enable(issue_vector_src1_enable),
        .issue_vector_src2_enable(issue_vector_src2_enable),
        .issue_vector_dst_enable(issue_vector_dst_enable),
        .issue_predicate_src_enable(issue_predicate_src_enable),
        .issue_predicate_dst_enable(issue_predicate_dst_enable),
        .issue_ready(issue_ready),
        .busy_vector_regs(busy_vector_regs),
        .busy_predicate_regs(busy_predicate_regs)
    );

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_path)) $fatal(1, "missing STIM");
        if (!$value$plusargs("OUT=%s", out_path)) $fatal(1, "missing OUT");

        stim_file = $fopen(stim_path, "r");
        out_file = $fopen(out_path, "w");
        if (stim_file == 0 || out_file == 0) $fatal(1, "file open failed");

        clk = 1'b0;
        rst = 1'b1;
        dispatch_valid = 1'b0;
        dispatch_pc = '0;
        dispatch_opcode = '0;
        dispatch_flags = '0;
        dispatch_dst = '0;
        dispatch_src0 = '0;
        dispatch_src1 = '0;
        dispatch_src2 = '0;
        dispatch_pred = '0;
        dispatch_vector_src0_enable = 1'b0;
        dispatch_vector_src1_enable = 1'b0;
        dispatch_vector_src2_enable = 1'b0;
        dispatch_vector_dst_enable = 1'b0;
        dispatch_predicate_src_enable = 1'b0;
        dispatch_predicate_dst_enable = 1'b0;
        issue_ready = 1'b0;
        busy_vector_regs = '0;
        busy_predicate_regs = '0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        cycle = 0;

        while (!$feof(stim_file)) begin
            scan_result = $fscanf(
                stim_file,
                "%d %h %h %h %h %h %h %h %h %d %d %d %d %d %d %d %h %h\n",
                dispatch_valid,
                dispatch_pc,
                dispatch_opcode,
                dispatch_flags,
                dispatch_dst,
                dispatch_src0,
                dispatch_src1,
                dispatch_src2,
                dispatch_pred,
                dispatch_vector_src0_enable,
                dispatch_vector_src1_enable,
                dispatch_vector_src2_enable,
                dispatch_vector_dst_enable,
                dispatch_predicate_src_enable,
                dispatch_predicate_dst_enable,
                issue_ready,
                busy_vector_regs,
                busy_predicate_regs
            );
            if (scan_result != 18) begin
                if (!$feof(stim_file)) $fatal(1, "bad stimulus record cycle=%0d fields=%0d", cycle, scan_result);
                break;
            end

            #1;
            $fdisplay(
                out_file,
                "%0d %0d %08x %02x %01x %02x %02x %02x %02x %01x %0d %0d %0d %0d %0d %0d",
                dispatch_ready,
                issue_valid,
                issue_pc,
                issue_opcode,
                issue_flags,
                issue_dst,
                issue_src0,
                issue_src1,
                issue_src2,
                issue_pred,
                issue_vector_src0_enable,
                issue_vector_src1_enable,
                issue_vector_src2_enable,
                issue_vector_dst_enable,
                issue_predicate_src_enable,
                issue_predicate_dst_enable
            );

            @(posedge clk);
            @(negedge clk);
            cycle = cycle + 1;
        end

        $fclose(stim_file);
        $fclose(out_file);
        $display("RTL5E_QUEUE_DIFF_TB=PASS cycles=%0d", cycle);
        $finish;
    end
endmodule
''')


def main():
    rng = random.Random(SEED)
    model = A0QueueModel(depth=DEPTH)

    with tempfile.TemporaryDirectory(prefix="a0_rtl5e_queue_diff_") as temp_dir:
        temp = Path(temp_dir)
        stim = temp / "stim.txt"
        out = temp / "rtl.txt"
        tb = temp / "a0_issue_queue_diff_tb.sv"
        obj = temp / "obj_dir"
        make_temp_tb(tb)

        expected = []
        accepted = 0
        pc_counter = 0x1000
        lines = []

        while accepted < RANDOM_INSTRUCTIONS or model.count:
            want_dispatch = accepted < RANDOM_INSTRUCTIONS and rng.random() < 0.88
            issue_ready = rng.random() < 0.78
            busy_vector = sparse_mask(rng, 64, 0.055)
            busy_predicate = sparse_mask(rng, 16, 0.055)

            payload = None
            instr = None
            deps = None
            if want_dispatch:
                instr = random_instruction(rng)
                deps = classifier_contract(instr)
                payload = QueuePayload(
                    pc=pc_counter,
                    instruction=instr,
                    deps=deps,
                )

            comb = model.combinational(
                issue_ready=issue_ready,
                busy_vector=busy_vector,
                busy_predicate=busy_predicate,
            )

            issue_payload = comb["issue_payload"]
            expected.append(
                (
                    int(comb["dispatch_ready"]),
                    int(comb["issue_valid"]),
                    *payload_tuple(issue_payload),
                )
            )

            if payload is None:
                line_payload = QueuePayload(
                    pc=0,
                    instruction=Instruction(opcode=Opcode.NOP),
                    deps=classifier_contract(Instruction(opcode=Opcode.NOP)),
                )
                dispatch_valid = 0
            else:
                line_payload = payload
                dispatch_valid = 1

            li = line_payload.instruction
            ld = line_payload.deps
            lines.append(
                " ".join(
                    [
                        str(dispatch_valid),
                        f"{line_payload.pc:08x}",
                        f"{int(li.opcode):02x}",
                        f"{li.flags:x}",
                        f"{li.dst:02x}",
                        f"{li.src0:02x}",
                        f"{li.src1:02x}",
                        f"{li.src2:02x}",
                        f"{li.pred:x}",
                        str(int(ld.vector_src0_enable)),
                        str(int(ld.vector_src1_enable)),
                        str(int(ld.vector_src2_enable)),
                        str(int(ld.vector_dst_enable)),
                        str(int(ld.predicate_src_enable)),
                        str(int(ld.predicate_dst_enable)),
                        str(int(issue_ready)),
                        f"{busy_vector:016x}",
                        f"{busy_predicate:04x}",
                    ]
                )
            )

            result = model.step(
                dispatch_payload=payload,
                issue_ready=issue_ready,
                busy_vector=busy_vector,
                busy_predicate=busy_predicate,
            )
            if payload is not None and result["dispatch_fire"]:
                accepted += 1
                pc_counter += 1

        stim.write_text("\n".join(lines) + "\n")

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-fatal",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "--top-module",
                "a0_issue_queue_diff_tb",
                "--Mdir",
                str(obj),
                str(RTL),
                str(tb),
            ],
            ROOT,
        )

        binary = obj / "Va0_issue_queue_diff_tb"
        sim_output = run(
            [str(binary), f"+STIM={stim}", f"+OUT={out}"],
            ROOT,
        )
        if "RTL5E_QUEUE_DIFF_TB=PASS" not in sim_output:
            raise RuntimeError("RTL5E differential TB did not report PASS")

        rtl_lines = [line.split() for line in out.read_text().splitlines()]
        if len(rtl_lines) != len(expected):
            raise AssertionError(
                f"cycle count mismatch RTL={len(rtl_lines)} model={len(expected)}"
            )

        for cycle, (tokens, exp) in enumerate(zip(rtl_lines, expected)):
            got = (
                int(tokens[0]),
                int(tokens[1]),
                int(tokens[2], 16),
                int(tokens[3], 16),
                int(tokens[4], 16),
                int(tokens[5], 16),
                int(tokens[6], 16),
                int(tokens[7], 16),
                int(tokens[8], 16),
                int(tokens[9], 16),
                int(tokens[10]),
                int(tokens[11]),
                int(tokens[12]),
                int(tokens[13]),
                int(tokens[14]),
                int(tokens[15]),
            )
            if got != exp:
                raise AssertionError(
                    f"RTL5E queue differential mismatch cycle={cycle}\n"
                    f"expected={exp}\n"
                    f"actual  ={got}"
                )

        print(
            "RTL5E_QUEUE_DIFF=PASS "
            f"seed=0x{SEED:x} accepted={accepted} cycles={len(expected)}"
        )


if __name__ == "__main__":
    main()
