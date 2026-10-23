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

from a0_wave_scheduler_model import A0WaveSchedulerModel  # noqa: E402


RTL = ROOT / "rtl/scheduler/a0_wave_scheduler.sv"

RESIDENT_WAVES = 3
SEED = 0xA071
RANDOM_CYCLES = 10_000


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
            f"{result.returncode}: "
            + " ".join(map(str, command))
        )
    return result.stdout


def make_tb(path: Path):
    path.write_text(
        r'''`timescale 1ns/1ps

module a0_wave_scheduler_diff_tb;

    localparam integer RESIDENT_WAVES = 3;
    localparam integer WAVE_ID_W = 2;
    localparam integer WAVE_COUNT_W = 2;

    logic clk;
    logic rst_n;

    logic [2:0] ready_mask_i;
    logic [2:0] memory_ready_mask_i;
    logic [2:0] non_memory_ready_mask_i;
    logic [2:0] memory_stalled_mask_i;
    logic [2:0] merge_ready_mask_i;

    logic [7:0] mshr_occupancy_i;
    logic [7:0] mshr_capacity_i;

    logic policy_override_valid_i;
    logic [WAVE_ID_W-1:0] policy_override_wave_i;
    logic grant_fire_i;

    logic grant_valid_o;
    logic [WAVE_ID_W-1:0] grant_wave_o;
    logic lrr_candidate_valid_o;
    logic [WAVE_ID_W-1:0] lrr_candidate_wave_o;
    logic policy_override_accepted_o;
    logic pressure_high_o;
    logic [2:0] merge_ready_visible_o;

    logic [WAVE_COUNT_W-1:0] ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] non_memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_stalled_count_o;
    logic [WAVE_COUNT_W-1:0] merge_ready_count_o;
    logic [WAVE_ID_W-1:0] rr_cursor_o;

    integer stim_file;
    integer out_file;
    integer scan_result;
    integer cycle;

    string stim_path;
    string out_path;


    a0_wave_scheduler #(
        .RESIDENT_WAVES(RESIDENT_WAVES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .ready_mask_i(ready_mask_i),
        .memory_ready_mask_i(memory_ready_mask_i),
        .non_memory_ready_mask_i(non_memory_ready_mask_i),
        .memory_stalled_mask_i(memory_stalled_mask_i),
        .merge_ready_mask_i(merge_ready_mask_i),
        .mshr_occupancy_i(mshr_occupancy_i),
        .mshr_capacity_i(mshr_capacity_i),
        .policy_override_valid_i(policy_override_valid_i),
        .policy_override_wave_i(policy_override_wave_i),
        .grant_fire_i(grant_fire_i),
        .grant_valid_o(grant_valid_o),
        .grant_wave_o(grant_wave_o),
        .lrr_candidate_valid_o(lrr_candidate_valid_o),
        .lrr_candidate_wave_o(lrr_candidate_wave_o),
        .policy_override_accepted_o(policy_override_accepted_o),
        .pressure_high_o(pressure_high_o),
        .merge_ready_visible_o(merge_ready_visible_o),
        .ready_count_o(ready_count_o),
        .memory_ready_count_o(memory_ready_count_o),
        .non_memory_ready_count_o(non_memory_ready_count_o),
        .memory_stalled_count_o(memory_stalled_count_o),
        .merge_ready_count_o(merge_ready_count_o),
        .rr_cursor_o(rr_cursor_o)
    );


    always #5 clk = ~clk;


    initial begin

        if (!$value$plusargs("STIM=%s", stim_path)) begin
            $fatal(1, "missing STIM plusarg");
        end

        if (!$value$plusargs("OUT=%s", out_path)) begin
            $fatal(1, "missing OUT plusarg");
        end

        stim_file = $fopen(stim_path, "r");
        out_file = $fopen(out_path, "w");

        if (
            stim_file == 0
            || out_file == 0
        ) begin
            $fatal(1, "failed to open scheduler diff files");
        end

        clk = 1'b0;
        rst_n = 1'b0;

        ready_mask_i = '0;
        memory_ready_mask_i = '0;
        non_memory_ready_mask_i = '0;
        memory_stalled_mask_i = '0;
        merge_ready_mask_i = '0;

        mshr_occupancy_i = '0;
        mshr_capacity_i = '0;

        policy_override_valid_i = 1'b0;
        policy_override_wave_i = '0;
        grant_fire_i = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        cycle = 0;

        while (!$feof(stim_file)) begin

            scan_result = $fscanf(
                stim_file,
                "%h %h %h %h %h %d %d %d %d %d\n",
                ready_mask_i,
                memory_ready_mask_i,
                non_memory_ready_mask_i,
                memory_stalled_mask_i,
                merge_ready_mask_i,
                mshr_occupancy_i,
                mshr_capacity_i,
                policy_override_valid_i,
                policy_override_wave_i,
                grant_fire_i
            );

            if (scan_result != 10) begin
                if (!$feof(stim_file)) begin
                    $fatal(
                        1,
                        "bad scheduler stimulus cycle=%0d fields=%0d",
                        cycle,
                        scan_result
                    );
                end
                break;
            end

            #1;

            $fdisplay(
                out_file,
                "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                grant_valid_o,
                grant_wave_o,
                lrr_candidate_valid_o,
                lrr_candidate_wave_o,
                policy_override_accepted_o,
                pressure_high_o,
                merge_ready_visible_o,
                ready_count_o,
                memory_ready_count_o,
                non_memory_ready_count_o,
                memory_stalled_count_o,
                merge_ready_count_o,
                rr_cursor_o
            );

            @(posedge clk);
            #1;
            @(negedge clk);

            cycle = cycle + 1;

        end

        $fclose(stim_file);
        $fclose(out_file);

        $display(
            "RTL7_SCHED_DIFF_TB=PASS cycles=%0d",
            cycle
        );

        $finish;
    end

endmodule
''',
        encoding="utf-8",
    )


def build_vectors():
    rng = random.Random(SEED)
    model = A0WaveSchedulerModel(
        resident_waves=RESIDENT_WAVES
    )

    stimulus = []
    expected = []

    directed = [
        (0b000, 0b000, 0b000, 0b000, 0b000, 0, 0, 0, 0, 0),
        (0b111, 0b101, 0b010, 0b000, 0b001, 0, 4, 0, 0, 1),
        (0b111, 0b101, 0b010, 0b001, 0b100, 2, 4, 0, 0, 1),
        (0b101, 0b101, 0b000, 0b010, 0b100, 2, 4, 1, 1, 0),
        (0b101, 0b101, 0b000, 0b010, 0b100, 2, 4, 1, 3, 1),
    ]

    records = list(directed)
    capacities = [0, 1, 2, 4, 8, 16, 32, 64]

    for _ in range(RANDOM_CYCLES):
        ready = rng.randrange(1 << RESIDENT_WAVES)
        mem = rng.randrange(1 << RESIDENT_WAVES)
        nonmem = rng.randrange(1 << RESIDENT_WAVES)
        stalled = rng.randrange(1 << RESIDENT_WAVES)
        merge = rng.randrange(1 << RESIDENT_WAVES)

        capacity = rng.choice(capacities)
        occupancy = (
            0
            if capacity == 0
            else rng.randrange(capacity + 1)
        )

        override_valid = rng.randrange(2)
        override_wave = rng.randrange(4)
        grant_fire = int(rng.random() < 0.72)

        records.append(
            (
                ready,
                mem,
                nonmem,
                stalled,
                merge,
                occupancy,
                capacity,
                override_valid,
                override_wave,
                grant_fire,
            )
        )

    mask_limit = (1 << RESIDENT_WAVES) - 1

    for record in records:
        (
            ready,
            mem,
            nonmem,
            stalled,
            merge,
            occupancy,
            capacity,
            override_valid,
            override_wave,
            grant_fire,
        ) = record

        observation = model.observe(
            ready_mask=ready,
            memory_ready_mask=mem,
            non_memory_ready_mask=nonmem,
            memory_stalled_mask=stalled,
            merge_ready_mask=merge,
            mshr_occupancy=occupancy,
            mshr_capacity=capacity,
            override_valid=override_valid,
            override_wave=override_wave,
        )

        merge_visible = (
            merge
            & ready
            & mem
            & mask_limit
        )

        expected.append(
            (
                observation.grant_valid,
                observation.grant_wave,
                observation.lrr_valid,
                observation.lrr_wave,
                observation.override_accepted,
                observation.pressure_high,
                merge_visible,
                observation.ready_count,
                observation.memory_ready_count,
                observation.non_memory_ready_count,
                observation.memory_stalled_count,
                observation.merge_ready_count,
                observation.rr_cursor,
            )
        )

        stimulus.append(record)

        model.step(
            observation,
            grant_fire=grant_fire,
        )

    return stimulus, expected


def main():
    stimulus, expected = build_vectors()

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl7_sched_diff_"
    ) as temp_dir:
        temp = Path(temp_dir)
        tb = temp / "a0_wave_scheduler_diff_tb.sv"
        stim = temp / "stim.txt"
        out = temp / "out.txt"
        build_dir = temp / "obj_dir"

        make_tb(tb)

        with stim.open("w", encoding="utf-8") as handle:
            for record in stimulus:
                (
                    ready,
                    mem,
                    nonmem,
                    stalled,
                    merge,
                    occupancy,
                    capacity,
                    override_valid,
                    override_wave,
                    grant_fire,
                ) = record

                handle.write(
                    f"{ready:x} {mem:x} {nonmem:x} "
                    f"{stalled:x} {merge:x} "
                    f"{occupancy} {capacity} "
                    f"{override_valid} {override_wave} "
                    f"{grant_fire}\n"
                )

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
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "--top-module",
                "a0_wave_scheduler_diff_tb",
                "--Mdir",
                str(build_dir),
                str(RTL),
                str(tb),
            ],
            ROOT,
        )

        output = run(
            [
                str(build_dir / "Va0_wave_scheduler_diff_tb"),
                f"+STIM={stim}",
                f"+OUT={out}",
            ],
            ROOT,
        )

        if "RTL7_SCHED_DIFF_TB=PASS" not in output:
            raise RuntimeError(
                "missing RTL7 scheduler diff TB PASS marker"
            )

        actual = []
        for line in out.read_text(
            encoding="utf-8"
        ).splitlines():
            if line.strip():
                actual.append(
                    tuple(int(field) for field in line.split())
                )

        if len(actual) != len(expected):
            raise RuntimeError(
                "scheduler diff record count mismatch: "
                f"expected={len(expected)} actual={len(actual)}"
            )

        for cycle, (exp, got) in enumerate(
            zip(expected, actual)
        ):
            if exp != got:
                raise RuntimeError(
                    "RTL7 scheduler differential mismatch "
                    f"cycle={cycle}\n"
                    f"expected={exp}\n"
                    f"actual={got}"
                )

        print(
            "RTL7_SCHEDULER_DIFF=PASS "
            f"seed=0x{SEED:04x} "
            f"cycles={len(expected)}"
        )


if __name__ == "__main__":
    main()
