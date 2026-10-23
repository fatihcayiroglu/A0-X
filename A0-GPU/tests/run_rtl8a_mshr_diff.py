#!/usr/bin/env python3

from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"
if str(SIM) not in sys.path:
    sys.path.insert(0, str(SIM))

from a0_mshr_model import A0MSHRModel  # noqa: E402

RTL = ROOT / "rtl/memory/a0_mshr_table.sv"
SEED = 0xA08A
CYCLES = 10_000
MSHR_COUNT = 4
RESIDENT_WAVES = 3
WAVE_SIZE = 4
LINE_WORDS = 4


def run(command):
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): "
            + " ".join(map(str, command))
        )
    return result.stdout


def make_tb(path: Path):
    path.write_text(
        r'''`timescale 1ns/1ps
module a0_mshr_diff_tb;
    localparam integer MSHR_COUNT = 4;
    localparam integer RESIDENT_WAVES = 3;
    localparam integer WAVE_SIZE = 4;
    localparam integer LINE_WORDS = 4;
    localparam integer LINE_ADDR_W = 10;
    localparam integer ENTRY_W = 2;
    localparam integer WAVE_ID_W = 2;
    localparam integer WORD_SELECT_W = 2;
    localparam integer OCCUPANCY_W = 3;

    logic clk;
    logic rst_n;
    logic req_valid_i;
    logic req_ready_o;
    logic [LINE_ADDR_W-1:0] req_line_addr_i;
    logic [WAVE_ID_W-1:0] req_wave_i;
    logic [WAVE_ID_W-1:0] req_context_i;
    logic [5:0] req_dst_i;
    logic [WAVE_SIZE-1:0] req_lane_mask_i;
    logic [WORD_SELECT_W-1:0] req_lane_word_select_i [0:WAVE_SIZE-1];
    logic req_fire_o;
    logic req_allocated_o;
    logic req_merged_o;
    logic req_blocked_draining_o;
    logic req_duplicate_waiter_o;
    logic [ENTRY_W-1:0] req_entry_o;
    logic miss_req_valid_o;
    logic miss_req_ready_i;
    logic [ENTRY_W-1:0] miss_req_entry_o;
    logic [LINE_ADDR_W-1:0] miss_req_line_addr_o;
    logic resp_valid_i;
    logic [ENTRY_W-1:0] resp_entry_i;
    logic [LINE_ADDR_W-1:0] resp_line_addr_i;
    logic resp_fault_i;
    logic [31:0] resp_line_data_i [0:LINE_WORDS-1];
    logic resp_accept_o;
    logic resp_tag_error_o;
    logic complete_valid_o;
    logic complete_ready_i;
    logic [ENTRY_W-1:0] complete_entry_o;
    logic [WAVE_ID_W-1:0] complete_wave_o;
    logic [WAVE_ID_W-1:0] complete_context_o;
    logic [5:0] complete_dst_o;
    logic [WAVE_SIZE-1:0] complete_lane_mask_o;
    logic [WORD_SELECT_W-1:0] complete_lane_word_select_o [0:WAVE_SIZE-1];
    logic complete_fault_o;
    logic [31:0] complete_line_data_o [0:LINE_WORDS-1];
    logic [OCCUPANCY_W-1:0] occupancy_o;
    logic full_o;
    logic empty_o;
    logic [MSHR_COUNT-1:0] valid_mask_o;
    logic [MSHR_COUNT-1:0] issued_mask_o;
    logic [MSHR_COUNT-1:0] response_ready_mask_o;

    integer stim_file;
    integer out_file;
    integer scan_result;
    integer cycle;
    string stim_path;
    string out_path;

    a0_mshr_table #(
        .MSHR_COUNT(MSHR_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) dut (.*);

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_path)) $fatal(1, "missing STIM");
        if (!$value$plusargs("OUT=%s", out_path)) $fatal(1, "missing OUT");
        stim_file = $fopen(stim_path, "r");
        out_file = $fopen(out_path, "w");
        if (stim_file == 0 || out_file == 0) $fatal(1, "file open failed");

        clk = 1'b0;
        rst_n = 1'b0;
        req_valid_i = 1'b0;
        req_line_addr_i = '0;
        req_wave_i = '0;
        req_context_i = '0;
        req_dst_i = '0;
        req_lane_mask_i = '0;
        req_lane_word_select_i[0] = '0;
        req_lane_word_select_i[1] = '0;
        req_lane_word_select_i[2] = '0;
        req_lane_word_select_i[3] = '0;
        miss_req_ready_i = 1'b0;
        resp_valid_i = 1'b0;
        resp_entry_i = '0;
        resp_line_addr_i = '0;
        resp_fault_i = 1'b0;
        resp_line_data_i[0] = '0;
        resp_line_data_i[1] = '0;
        resp_line_data_i[2] = '0;
        resp_line_data_i[3] = '0;
        complete_ready_i = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        cycle = 0;

        while (!$feof(stim_file)) begin
            scan_result = $fscanf(
                stim_file,
                "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                req_valid_i,
                req_line_addr_i,
                req_wave_i,
                req_context_i,
                req_dst_i,
                req_lane_mask_i,
                req_lane_word_select_i[0],
                req_lane_word_select_i[1],
                req_lane_word_select_i[2],
                req_lane_word_select_i[3],
                miss_req_ready_i,
                resp_valid_i,
                resp_entry_i,
                resp_line_addr_i,
                resp_fault_i,
                resp_line_data_i[0],
                resp_line_data_i[1],
                resp_line_data_i[2],
                resp_line_data_i[3],
                complete_ready_i
            );
            if (scan_result != 20) begin
                if (!$feof(stim_file)) begin
                    $fatal(1, "bad stimulus cycle=%0d fields=%0d", cycle, scan_result);
                end
                break;
            end

            #1;
            $fdisplay(
                out_file,
                "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                req_ready_o,
                req_fire_o,
                req_allocated_o,
                req_merged_o,
                req_blocked_draining_o,
                req_duplicate_waiter_o,
                req_entry_o,
                miss_req_valid_o,
                miss_req_entry_o,
                miss_req_line_addr_o,
                resp_accept_o,
                resp_tag_error_o,
                complete_valid_o,
                complete_entry_o,
                complete_wave_o,
                complete_context_o,
                complete_dst_o,
                complete_lane_mask_o,
                complete_fault_o,
                complete_lane_word_select_o[0],
                complete_lane_word_select_o[1],
                complete_lane_word_select_o[2],
                complete_lane_word_select_o[3],
                complete_line_data_o[0],
                complete_line_data_o[1],
                complete_line_data_o[2],
                complete_line_data_o[3],
                occupancy_o,
                full_o,
                empty_o,
                valid_mask_o,
                issued_mask_o,
                response_ready_mask_o
            );

            @(posedge clk);
            #1;
            @(negedge clk);
            cycle = cycle + 1;
        end

        $fclose(stim_file);
        $fclose(out_file);
        $display("RTL8A_MSHR_DIFF_TB=PASS cycles=%0d", cycle);
        $finish;
    end
endmodule
''',
        encoding="utf-8",
    )


def generate_vectors():
    rng = random.Random(SEED)
    model = A0MSHRModel(
        mshr_count=MSHR_COUNT,
        resident_waves=RESIDENT_WAVES,
        wave_size=WAVE_SIZE,
        line_words=LINE_WORDS,
    )

    stimulus = []
    expected = []
    stats = {
        "allocations": 0,
        "merges": 0,
        "full_stalls": 0,
        "draining_stalls": 0,
        "duplicates": 0,
        "responses": 0,
        "tag_errors": 0,
        "completions": 0,
    }

    for cycle in range(CYCLES):
        open_entries = [
            entry
            for entry in model.entries
            if entry.valid and not entry.response_ready
        ]
        issued_entries = [
            (index, entry)
            for index, entry in enumerate(model.entries)
            if entry.valid and entry.issued and not entry.response_ready
        ]

        req_valid = int(rng.random() < 0.72)
        if open_entries and rng.random() < 0.38:
            req_line = rng.choice(open_entries).line_addr
        else:
            req_line = rng.randrange(64)

        req_wave = 3 if rng.random() < 0.08 else rng.randrange(RESIDENT_WAVES)
        req_context = rng.randrange(RESIDENT_WAVES)
        req_dst = rng.randrange(64)
        req_lane_mask = 0 if rng.random() < 0.04 else rng.randrange(1, 1 << WAVE_SIZE)
        req_word_select = tuple(rng.randrange(LINE_WORDS) for _ in range(WAVE_SIZE))

        miss_ready = int(rng.random() < 0.68)

        resp_valid = int(rng.random() < 0.34)
        if resp_valid and issued_entries and rng.random() < 0.76:
            resp_entry, entry = rng.choice(issued_entries)
            resp_line = entry.line_addr if rng.random() < 0.82 else (entry.line_addr ^ 1)
        else:
            resp_entry = rng.randrange(MSHR_COUNT)
            resp_line = rng.randrange(64)
        resp_fault = int(rng.random() < 0.08)
        resp_line_data = tuple(
            100_000 + cycle * 8 + word
            for word in range(LINE_WORDS)
        )
        complete_ready = int(rng.random() < 0.71)

        kwargs = dict(
            req_valid=req_valid,
            req_line=req_line,
            req_wave=req_wave,
            req_context=req_context,
            req_dst=req_dst,
            req_lane_mask=req_lane_mask,
            req_word_select=req_word_select,
            miss_ready=miss_ready,
            resp_valid=resp_valid,
            resp_entry=resp_entry,
            resp_line=resp_line,
            resp_fault=resp_fault,
            resp_line_data=resp_line_data,
            complete_ready=complete_ready,
        )

        observation = model.observe(**kwargs)

        expected.append(
            (
                observation.req_ready,
                observation.req_fire,
                observation.req_allocated,
                observation.req_merged,
                observation.req_blocked_draining,
                observation.req_duplicate_waiter,
                observation.req_entry,
                observation.miss_valid,
                observation.miss_entry,
                observation.miss_line,
                observation.resp_accept,
                observation.resp_tag_error,
                observation.complete_valid,
                observation.complete_entry,
                observation.complete_wave,
                observation.complete_context,
                observation.complete_dst,
                observation.complete_lane_mask,
                observation.complete_fault,
                *observation.complete_word_select,
                *observation.complete_line_data,
                observation.occupancy,
                observation.full,
                observation.empty,
                observation.valid_mask,
                observation.issued_mask,
                observation.response_ready_mask,
            )
        )

        stimulus.append(
            (
                req_valid,
                req_line,
                req_wave,
                req_context,
                req_dst,
                req_lane_mask,
                *req_word_select,
                miss_ready,
                resp_valid,
                resp_entry,
                resp_line,
                resp_fault,
                *resp_line_data,
                complete_ready,
            )
        )

        stats["allocations"] += observation.req_allocated
        stats["merges"] += observation.req_merged
        stats["full_stalls"] += int(
            bool(req_valid)
            and bool(observation.full)
            and not bool(observation.req_ready)
        )
        stats["draining_stalls"] += observation.req_blocked_draining
        stats["duplicates"] += observation.req_duplicate_waiter
        stats["responses"] += observation.resp_accept
        stats["tag_errors"] += observation.resp_tag_error
        stats["completions"] += int(
            bool(observation.complete_valid) and bool(complete_ready)
        )

        model.step(observation, **kwargs)
        model.assert_invariants()

    return stimulus, expected, stats


def main():
    stimulus, expected, stats = generate_vectors()

    if stats["merges"] < 100:
        raise RuntimeError(f"insufficient merge coverage: {stats}")
    if stats["responses"] < 250:
        raise RuntimeError(f"insufficient response coverage: {stats}")
    if stats["completions"] < 250:
        raise RuntimeError(f"insufficient completion coverage: {stats}")
    if stats["tag_errors"] < 250:
        raise RuntimeError(f"insufficient tag-error coverage: {stats}")

    with tempfile.TemporaryDirectory(prefix="a0_rtl8a_mshr_diff_") as temp_dir:
        temp = Path(temp_dir)
        tb = temp / "a0_mshr_diff_tb.sv"
        stim = temp / "stim.txt"
        out = temp / "out.txt"
        obj = temp / "obj_dir"
        make_tb(tb)

        with stim.open("w", encoding="utf-8") as handle:
            for record in stimulus:
                handle.write(" ".join(str(value) for value in record) + "\n")

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_mshr_diff_tb",
                "--Mdir",
                str(obj),
                str(RTL),
                str(tb),
            ]
        )

        simulation = run(
            [
                str(obj / "Va0_mshr_diff_tb"),
                f"+STIM={stim}",
                f"+OUT={out}",
            ]
        )
        if "RTL8A_MSHR_DIFF_TB=PASS" not in simulation:
            raise RuntimeError("missing RTL8A MSHR diff TB marker")

        actual = [
            tuple(int(field) for field in line.split())
            for line in out.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if len(actual) != len(expected):
            raise RuntimeError(
                f"record-count mismatch expected={len(expected)} actual={len(actual)}"
            )

        for cycle, (exp, got) in enumerate(zip(expected, actual)):
            if exp != got:
                raise RuntimeError(
                    "RTL8A MSHR differential mismatch "
                    f"cycle={cycle}\nexpected={exp}\nactual={got}"
                )

    print(
        "RTL8A_MSHR_DIFF=PASS "
        f"seed=0x{SEED:04x} cycles={CYCLES} "
        f"allocations={stats['allocations']} merges={stats['merges']} "
        f"responses={stats['responses']} completions={stats['completions']} "
        f"tag_errors={stats['tag_errors']} full_stalls={stats['full_stalls']} "
        f"draining_stalls={stats['draining_stalls']} duplicates={stats['duplicates']}"
    )


if __name__ == "__main__":
    main()
