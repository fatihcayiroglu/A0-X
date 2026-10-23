#!/usr/bin/env python3

from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "rtl/core/a0_vector_operand_path_contexted.sv"
COLLECTOR = ROOT / "rtl/core/a0_operand_collector.sv"
REGFILE = ROOT / "rtl/core/a0_regfile_banked_contexted.sv"

CONTEXT_COUNT = 4
VECTOR_REG_COUNT = 16
WAVE_SIZE = 16
PHYSICAL_LANES = 4
BEAT_COUNT = 4
TRANSACTIONS = 10_000
SEED = 0xA07B
DATA_W = PHYSICAL_LANES * 32
DATA_HEX_DIGITS = DATA_W // 4


def run(command, cwd=ROOT):
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
            f"{result.returncode}: "
            + " ".join(map(str, command))
        )
    return result.stdout


def lane_word(context: int, reg: int, beat: int, lane: int) -> int:
    return (
        0x7000_0000
        ^ ((context & 0x3) << 24)
        ^ ((reg & 0xF) << 16)
        ^ ((beat & 0x3) << 8)
        ^ lane
    ) & 0xFFFF_FFFF


def beat_value(context: int, reg: int, beat: int) -> int:
    value = 0
    for lane in range(PHYSICAL_LANES):
        value |= lane_word(context, reg, beat, lane) << (lane * 32)
    return value


def make_tb(path: Path):
    path.write_text(
        r'''`timescale 1ns/1ps

module a0_context_vrf_diff_tb;
    localparam integer CONTEXT_COUNT = 4;
    localparam integer VECTOR_REG_COUNT = 16;
    localparam integer WAVE_SIZE = 16;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer BANK_COUNT = 4;
    localparam integer DATA_W = PHYSICAL_LANES * 32;
    localparam integer TRANSACTIONS = 10000;

    logic clk;
    logic rst_n;

    logic req_valid;
    logic req_ready;
    logic [1:0] req_context;
    logic req_src0_enable;
    logic req_src1_enable;
    logic req_src2_enable;
    logic [3:0] req_src0;
    logic [3:0] req_src1;
    logic [3:0] req_src2;
    logic [1:0] req_beat;

    logic result_valid;
    logic result_ready;
    logic [DATA_W-1:0] result_src0_data;
    logic [DATA_W-1:0] result_src1_data;
    logic [DATA_W-1:0] result_src2_data;
    logic busy;
    logic bank_conflict_cycle;

    logic write_valid;
    logic [1:0] write_context;
    logic [3:0] write_reg;
    logic [1:0] write_beat;
    logic [PHYSICAL_LANES-1:0] write_lane_mask;
    logic [DATA_W-1:0] write_data;
    logic write_ready;

    integer req_file;
    integer out_file;
    integer scan_result;
    integer context_index;
    integer reg_index;
    integer beat_index;
    integer sent;
    integer received;
    integer cycles;
    integer conflict_cycles;
    integer loaded;

    logic [31:0] lfsr;
    logic accept_req;
    logic accept_result;

    string req_path;
    string out_path;


    a0_vector_operand_path_contexted #(
        .CONTEXT_COUNT(CONTEXT_COUNT),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_context(req_context),
        .req_src0_enable(req_src0_enable),
        .req_src1_enable(req_src1_enable),
        .req_src2_enable(req_src2_enable),
        .req_src0(req_src0),
        .req_src1(req_src1),
        .req_src2(req_src2),
        .req_beat(req_beat),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_src0_data(result_src0_data),
        .result_src1_data(result_src1_data),
        .result_src2_data(result_src2_data),
        .busy(busy),
        .bank_conflict_cycle(bank_conflict_cycle),
        .write_valid(write_valid),
        .write_context(write_context),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );


    always #5 clk = ~clk;


    function automatic logic [DATA_W-1:0] init_beat(
        input integer c,
        input integer r,
        input integer b
    );
        integer l;
        logic [31:0] word;
        begin
            init_beat = '0;
            for (l = 0; l < PHYSICAL_LANES; l = l + 1) begin
                word =
                    32'h7000_0000
                    ^ (c << 24)
                    ^ (r << 16)
                    ^ (b << 8)
                    ^ l;
                init_beat[l*32 +: 32] = word;
            end
        end
    endfunction


    initial begin
        if (!$value$plusargs("REQ=%s", req_path)) begin
            $fatal(1, "missing REQ plusarg");
        end
        if (!$value$plusargs("OUT=%s", out_path)) begin
            $fatal(1, "missing OUT plusarg");
        end

        req_file = $fopen(req_path, "r");
        out_file = $fopen(out_path, "w");
        if (req_file == 0 || out_file == 0) begin
            $fatal(1, "failed to open RTL7B context VRF diff files");
        end

        clk = 1'b0;
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_context = '0;
        req_src0_enable = 1'b0;
        req_src1_enable = 1'b0;
        req_src2_enable = 1'b0;
        req_src0 = '0;
        req_src1 = '0;
        req_src2 = '0;
        req_beat = '0;
        result_ready = 1'b0;
        write_valid = 1'b0;
        write_context = '0;
        write_reg = '0;
        write_beat = '0;
        write_lane_mask = '0;
        write_data = '0;
        lfsr = 32'h7B01_CAFE;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (
            context_index = 0;
            context_index < CONTEXT_COUNT;
            context_index = context_index + 1
        ) begin
            for (
                reg_index = 0;
                reg_index < VECTOR_REG_COUNT;
                reg_index = reg_index + 1
            ) begin
                for (
                    beat_index = 0;
                    beat_index < 4;
                    beat_index = beat_index + 1
                ) begin
                    write_valid = 1'b1;
                    write_context = context_index[1:0];
                    write_reg = reg_index[3:0];
                    write_beat = beat_index[1:0];
                    write_lane_mask = '1;
                    write_data = init_beat(
                        context_index,
                        reg_index,
                        beat_index
                    );
                    #1;
                    if (!write_ready) begin
                        $fatal(
                            1,
                            "context VRF init rejected ctx=%0d reg=%0d beat=%0d",
                            context_index,
                            reg_index,
                            beat_index
                        );
                    end
                    @(posedge clk);
                    #1;
                    @(negedge clk);
                end
            end
        end

        write_valid = 1'b0;
        write_lane_mask = '0;
        write_data = '0;

        sent = 0;
        received = 0;
        cycles = 0;
        conflict_cycles = 0;
        loaded = 0;

        while (received < TRANSACTIONS) begin
            if (!req_valid && sent < TRANSACTIONS) begin
                scan_result = $fscanf(
                    req_file,
                    "%d %d %d %d %h %h %h %h\n",
                    req_context,
                    req_src0_enable,
                    req_src1_enable,
                    req_src2_enable,
                    req_src0,
                    req_src1,
                    req_src2,
                    req_beat
                );
                if (scan_result != 8) begin
                    $fatal(
                        1,
                        "bad context VRF request sent=%0d fields=%0d",
                        sent,
                        scan_result
                    );
                end
                req_valid = 1'b1;
                loaded = loaded + 1;
            end

            result_ready = lfsr[0] | lfsr[5];
            #1;

            accept_req = req_valid && req_ready;
            accept_result = result_valid && result_ready;

            /*
             * Public operand-path ownership contract: busy reflects an
             * owned transaction, while req_ready may reopen only for an
             * empty collector or same-cycle completed-result handoff.
             */
            if (req_ready !== (!busy || (result_valid && result_ready))) begin
                $fatal(
                    1,
                    "context VRF busy/ready contract mismatch busy=%0b req_ready=%0b result_valid=%0b result_ready=%0b",
                    busy,
                    req_ready,
                    result_valid,
                    result_ready
                );
            end

            if (bank_conflict_cycle) begin
                conflict_cycles = conflict_cycles + 1;
            end

            if (accept_result) begin
                $fdisplay(
                    out_file,
                    "%032x %032x %032x",
                    result_src0_data,
                    result_src1_data,
                    result_src2_data
                );
            end

            @(posedge clk);
            #1;

            if (accept_req) begin
                sent = sent + 1;
                req_valid = 1'b0;
            end
            if (accept_result) begin
                received = received + 1;
            end

            lfsr = {
                lfsr[30:0],
                lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]
            };

            cycles = cycles + 1;
            if (cycles > 200000) begin
                $fatal(
                    1,
                    "RTL7B context VRF diff timeout sent=%0d recv=%0d",
                    sent,
                    received
                );
            end

            @(negedge clk);
        end

        $fclose(req_file);
        $fclose(out_file);

        if (sent != TRANSACTIONS || loaded != TRANSACTIONS) begin
            $fatal(
                1,
                "context VRF count mismatch sent=%0d loaded=%0d",
                sent,
                loaded
            );
        end
        if (conflict_cycles == 0) begin
            $fatal(1, "context VRF random stream produced no bank conflicts");
        end

        $display(
            "RTL7B_CONTEXT_VRF_DIFF_TB=PASS transactions=%0d cycles=%0d conflicts=%0d",
            received,
            cycles,
            conflict_cycles
        );
        $finish;
    end
endmodule
''',
        encoding="utf-8",
    )


def main():
    rng = random.Random(SEED)
    requests = []
    expected = []

    for _ in range(TRANSACTIONS):
        context = rng.randrange(CONTEXT_COUNT)
        enables = [rng.randrange(2) for _ in range(3)]
        regs = [rng.randrange(VECTOR_REG_COUNT) for _ in range(3)]
        beat = rng.randrange(BEAT_COUNT)

        requests.append((context, *enables, *regs, beat))
        expected.append(
            tuple(
                beat_value(context, regs[index], beat)
                if enables[index]
                else 0
                for index in range(3)
            )
        )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl7b_context_vrf_diff_"
    ) as temp_dir:
        temp = Path(temp_dir)
        req_path = temp / "requests.txt"
        out_path = temp / "results.txt"
        tb_path = temp / "a0_context_vrf_diff_tb.sv"
        obj_dir = temp / "obj_dir"

        with req_path.open("w", encoding="utf-8") as handle:
            for record in requests:
                context, en0, en1, en2, src0, src1, src2, beat = record
                handle.write(
                    f"{context} {en0} {en1} {en2} "
                    f"{src0:x} {src1:x} {src2:x} {beat:x}\n"
                )

        make_tb(tb_path)
        obj_dir.mkdir(parents=True, exist_ok=True)

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-fatal",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_context_vrf_diff_tb",
                "--Mdir",
                str(obj_dir),
                str(COLLECTOR),
                str(REGFILE),
                str(PATH),
                str(tb_path),
            ]
        )

        output = run(
            [
                str(obj_dir / "Va0_context_vrf_diff_tb"),
                f"+REQ={req_path}",
                f"+OUT={out_path}",
            ]
        )

        if "RTL7B_CONTEXT_VRF_DIFF_TB=PASS" not in output:
            raise RuntimeError("missing RTL7B context VRF TB PASS marker")

        lines = out_path.read_text(encoding="utf-8").splitlines()
        if len(lines) != TRANSACTIONS:
            raise RuntimeError(
                f"result count mismatch: expected {TRANSACTIONS}, got {len(lines)}"
            )

        for index, (line, expected_values) in enumerate(
            zip(lines, expected)
        ):
            fields = line.split()
            if len(fields) != 3:
                raise RuntimeError(
                    f"bad RTL7B context VRF result line {index}: {line!r}"
                )
            actual = tuple(int(field, 16) for field in fields)
            if actual != expected_values:
                raise RuntimeError(
                    "RTL7B context VRF differential mismatch at transaction "
                    f"{index}: actual={actual}, expected={expected_values}, "
                    f"request={requests[index]}"
                )

        print(
            "RTL7B_CONTEXT_VRF_DIFF=PASS "
            f"seed=0x{SEED:x} contexts={CONTEXT_COUNT} "
            f"transactions={TRANSACTIONS}"
        )


if __name__ == "__main__":
    main()
