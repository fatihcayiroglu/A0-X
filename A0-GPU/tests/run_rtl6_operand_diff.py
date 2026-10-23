#!/usr/bin/env python3

from pathlib import Path
import random
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REGFILE = ROOT / "rtl/core/a0_regfile_banked.sv"
COLLECTOR = ROOT / "rtl/core/a0_operand_collector.sv"

VECTOR_REG_COUNT = 64
WAVE_SIZE = 32
PHYSICAL_LANES = 8
BEAT_COUNT = WAVE_SIZE // PHYSICAL_LANES
TRANSACTIONS = 10_000
SEED = 0xA061
DATA_W = PHYSICAL_LANES * 32
DATA_HEX_DIGITS = DATA_W // 4


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


def lane_word(reg: int, beat: int, lane: int) -> int:
    return (
        0xA000_0000
        ^ ((reg & 0x3F) << 16)
        ^ ((beat & 0x3) << 8)
        ^ lane
    ) & 0xFFFF_FFFF


def beat_value(reg: int, beat: int) -> int:
    value = 0
    for lane in range(PHYSICAL_LANES):
        value |= lane_word(reg, beat, lane) << (lane * 32)
    return value


def make_tb(path: Path):
    path.write_text(r'''`timescale 1ns/1ps

module a0_operand_diff_tb;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer BANK_COUNT = 4;
    localparam integer DATA_W = PHYSICAL_LANES * 32;
    localparam integer TRANSACTIONS = 10000;

    logic clk;
    logic rst_n;

    logic req_valid;
    logic req_ready;
    logic req_src0_enable;
    logic req_src1_enable;
    logic req_src2_enable;
    logic [5:0] req_src0;
    logic [5:0] req_src1;
    logic [5:0] req_src2;
    logic [1:0] req_beat;

    logic result_valid;
    logic result_ready;
    logic [DATA_W-1:0] result_src0_data;
    logic [DATA_W-1:0] result_src1_data;
    logic [DATA_W-1:0] result_src2_data;
    logic collector_busy;
    logic bank_conflict_cycle;

    logic [2:0] rf_read_valid;
    logic [5:0] rf_read_reg [0:2];
    logic [1:0] rf_read_beat [0:2];
    logic [2:0] rf_read_ready;
    logic [2:0] rf_read_bank_conflict;
    logic [2:0] rf_read_resp_valid;
    logic [DATA_W-1:0] rf_read_resp_data [0:2];

    logic write_valid;
    logic [5:0] write_reg;
    logic [1:0] write_beat;
    logic [PHYSICAL_LANES-1:0] write_lane_mask;
    logic [DATA_W-1:0] write_data;
    logic write_ready;

    integer req_file;
    integer out_file;
    integer scan_result;
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


    a0_operand_collector #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES)
    ) collector (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
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
        .busy(collector_busy),
        .bank_conflict_cycle(bank_conflict_cycle),
        .rf_read_valid(rf_read_valid),
        .rf_read_reg(rf_read_reg),
        .rf_read_beat(rf_read_beat),
        .rf_read_ready(rf_read_ready),
        .rf_read_bank_conflict(rf_read_bank_conflict),
        .rf_read_resp_valid(rf_read_resp_valid),
        .rf_read_resp_data(rf_read_resp_data)
    );


    a0_regfile_banked #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT),
        .READ_PORTS(3)
    ) regfile (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid(rf_read_valid),
        .read_reg(rf_read_reg),
        .read_beat(rf_read_beat),
        .read_ready(rf_read_ready),
        .read_bank_conflict(rf_read_bank_conflict),
        .read_resp_valid(rf_read_resp_valid),
        .read_resp_data(rf_read_resp_data),
        .write_valid(write_valid),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );


    always #5 clk = ~clk;


    function automatic logic [DATA_W-1:0] init_beat(
        input integer r,
        input integer b
    );
        integer l;
        logic [31:0] word;
        begin
            init_beat = '0;
            for (l = 0; l < PHYSICAL_LANES; l = l + 1) begin
                word = 32'hA000_0000 ^ (r << 16) ^ (b << 8) ^ l;
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
            $fatal(1, "failed to open diff files");
        end

        clk = 1'b0;
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_src0_enable = 1'b0;
        req_src1_enable = 1'b0;
        req_src2_enable = 1'b0;
        req_src0 = '0;
        req_src1 = '0;
        req_src2 = '0;
        req_beat = '0;
        result_ready = 1'b0;
        write_valid = 1'b0;
        write_reg = '0;
        write_beat = '0;
        write_lane_mask = '0;
        write_data = '0;
        lfsr = 32'h61A0_5EED;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        /* Initialize every architectural register beat through the real port. */
        for (reg_index = 0; reg_index < VECTOR_REG_COUNT; reg_index = reg_index + 1) begin
            for (beat_index = 0; beat_index < 4; beat_index = beat_index + 1) begin
                write_valid = 1'b1;
                write_reg = reg_index[5:0];
                write_beat = beat_index[1:0];
                write_lane_mask = '1;
                write_data = init_beat(reg_index, beat_index);
                #1;
                if (!write_ready) begin
                    $fatal(1, "initialization write rejected r=%0d b=%0d", reg_index, beat_index);
                end
                @(posedge clk);
                #1;
                @(negedge clk);
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
                    "%d %d %d %h %h %h %h\n",
                    req_src0_enable,
                    req_src1_enable,
                    req_src2_enable,
                    req_src0,
                    req_src1,
                    req_src2,
                    req_beat
                );
                if (scan_result != 7) begin
                    $fatal(1, "bad request record sent=%0d fields=%0d", sent, scan_result);
                end
                req_valid = 1'b1;
                loaded = loaded + 1;
            end

            result_ready = lfsr[0] | lfsr[5];
            #1;

            accept_req = req_valid && req_ready;
            accept_result = result_valid && result_ready;

            if (bank_conflict_cycle) begin
                conflict_cycles = conflict_cycles + 1;
            end

            if (accept_result) begin
                $fdisplay(
                    out_file,
                    "%064x %064x %064x",
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
                $fatal(1, "RTL6 operand diff timeout sent=%0d recv=%0d", sent, received);
            end

            @(negedge clk);
        end

        $fclose(req_file);
        $fclose(out_file);

        if (sent != TRANSACTIONS || loaded != TRANSACTIONS) begin
            $fatal(1, "request count mismatch sent=%0d loaded=%0d", sent, loaded);
        end
        if (conflict_cycles == 0) begin
            $fatal(1, "randomized operand stream produced no bank conflicts");
        end
        if (collector_busy) begin
            $fatal(1, "operand collector remained busy after final result retirement");
        end

        $display(
            "RTL6_OPERAND_DIFF_TB=PASS transactions=%0d cycles=%0d conflicts=%0d",
            received,
            cycles,
            conflict_cycles
        );
        $finish;
    end
endmodule
''')


def main():
    rng = random.Random(SEED)
    requests = []
    expected = []

    for _ in range(TRANSACTIONS):
        enables = [rng.randrange(2) for _ in range(3)]
        regs = [rng.randrange(VECTOR_REG_COUNT) for _ in range(3)]
        beat = rng.randrange(BEAT_COUNT)

        requests.append((*enables, *regs, beat))
        expected.append(
            tuple(
                beat_value(regs[index], beat) if enables[index] else 0
                for index in range(3)
            )
        )

    with tempfile.TemporaryDirectory(prefix="a0_rtl6_operand_diff_") as temp_dir:
        temp = Path(temp_dir)
        req_path = temp / "requests.txt"
        out_path = temp / "results.txt"
        tb_path = temp / "a0_operand_diff_tb.sv"
        obj_dir = temp / "obj_dir"

        with req_path.open("w", encoding="utf-8") as handle:
            for record in requests:
                en0, en1, en2, src0, src1, src2, beat = record
                handle.write(
                    f"{en0} {en1} {en2} "
                    f"{src0:02x} {src1:02x} {src2:02x} {beat:x}\n"
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
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "--top-module",
                "a0_operand_diff_tb",
                "--Mdir",
                str(obj_dir),
                str(REGFILE),
                str(COLLECTOR),
                str(tb_path),
            ],
            ROOT,
        )

        output = run(
            [
                str(obj_dir / "Va0_operand_diff_tb"),
                f"+REQ={req_path}",
                f"+OUT={out_path}",
            ],
            ROOT,
        )

        if "RTL6_OPERAND_DIFF_TB=PASS" not in output:
            raise RuntimeError("missing RTL6 operand diff PASS marker")

        lines = out_path.read_text(encoding="utf-8").splitlines()
        if len(lines) != TRANSACTIONS:
            raise RuntimeError(
                f"result count mismatch: expected {TRANSACTIONS}, got {len(lines)}"
            )

        for index, (line, expected_values) in enumerate(zip(lines, expected)):
            fields = line.split()
            if len(fields) != 3:
                raise RuntimeError(f"bad RTL result line {index}: {line!r}")
            actual = tuple(int(field, 16) for field in fields)
            if actual != expected_values:
                raise RuntimeError(
                    "RTL6 operand differential mismatch at transaction "
                    f"{index}: actual={actual}, expected={expected_values}, "
                    f"request={requests[index]}"
                )

        print(
            "RTL6_OPERAND_DIFF=PASS "
            f"seed=0x{SEED:x} transactions={TRANSACTIONS}"
        )


if __name__ == "__main__":
    main()
