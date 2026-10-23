`timescale 1ns/1ps

module a0_lane_sequencer_tb #(
    parameter integer PHYSICAL_LANES = 8
);

    localparam integer WAVE_SIZE = 32;

    localparam integer EXPECTED_BEATS =
        (
            WAVE_SIZE
            + PHYSICAL_LANES
            - 1
        )
        / PHYSICAL_LANES;


    logic clk;
    logic rst_n;

    logic start;

    logic [WAVE_SIZE-1:0]
        exec_mask;

    logic pred_enable;

    logic [WAVE_SIZE-1:0]
        pred_mask;


    logic busy;
    logic done;
    logic beat_valid;

    logic [$clog2(WAVE_SIZE)-1:0]
        beat_index;

    logic [PHYSICAL_LANES-1:0]
        physical_valid_mask;

    logic [PHYSICAL_LANES-1:0]
        physical_active_mask;

    logic [$clog2(WAVE_SIZE)-1:0]
        logical_lane [0:PHYSICAL_LANES-1];


    integer result_file;

    integer lane;
    integer physical_lane;
    integer beats_seen;


    a0_lane_sequencer #(
        .WAVE_SIZE(
            WAVE_SIZE
        ),
        .PHYSICAL_LANES(
            PHYSICAL_LANES
        )
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .advance_enable(1'b1),

        .start(start),

        .exec_mask(exec_mask),
        .pred_enable(pred_enable),
        .pred_mask(pred_mask),

        .busy(busy),
        .done(done),
        .beat_valid(beat_valid),

        .beat_index(beat_index),

        .physical_valid_mask(
            physical_valid_mask
        ),

        .physical_active_mask(
            physical_active_mask
        ),

        .logical_lane(
            logical_lane
        )
    );


    always #1 clk = ~clk;


    task automatic run_scenario(
        input integer scenario_id,

        input logic [WAVE_SIZE-1:0]
            scenario_exec,

        input logic
            scenario_pred_enable,

        input logic [WAVE_SIZE-1:0]
            scenario_pred
    );

        begin

            exec_mask =
                scenario_exec;

            pred_enable =
                scenario_pred_enable;

            pred_mask =
                scenario_pred;


            /*
             * Launch across one rising edge.
             */
            @(negedge clk);
            start = 1'b1;

            @(negedge clk);
            start = 1'b0;

            if (!busy) begin
                $fatal(1, "RTL4A busy missing after accepted start");
            end


            beats_seen = 0;


            while (beat_valid) begin

                $fwrite(
                    result_file,
                    "%0d %0d %0h %0h",
                    scenario_id,
                    beat_index,
                    physical_valid_mask,
                    physical_active_mask
                );


                for (
                    physical_lane = 0;
                    physical_lane < PHYSICAL_LANES;
                    physical_lane =
                        physical_lane + 1
                ) begin

                    $fwrite(
                        result_file,
                        " %0d",
                        logical_lane[
                            physical_lane
                        ]
                    );
                end


                $fwrite(
                    result_file,
                    "\n"
                );


                beats_seen =
                    beats_seen + 1;


                @(negedge clk);
            end


            if (!done) begin

                $fatal(
                    1,
                    "RTL4A done pulse missing"
                );
            end

            if (busy) begin
                $fatal(1, "RTL4A busy remained asserted at completion");
            end


            if (
                beats_seen
                != EXPECTED_BEATS
            ) begin

                $fatal(
                    1,
                    "RTL4A beat count mismatch expected=%0d actual=%0d",
                    EXPECTED_BEATS,
                    beats_seen
                );
            end


            /*
             * done must be exactly one cycle.
             */
            @(negedge clk);

            if (done) begin

                $fatal(
                    1,
                    "RTL4A done pulse longer than one cycle"
                );
            end
        end
    endtask


    initial begin

        clk = 1'b0;
        rst_n = 1'b0;

        start = 1'b0;

        exec_mask = '0;
        pred_enable = 1'b0;
        pred_mask = '0;


        result_file =
            $fopen(
                "rtl4a_result.txt",
                "w"
            );


        if (result_file == 0) begin

            $fatal(
                1,
                "RTL4A result-file open failed"
            );
        end


        repeat (2) begin
            @(negedge clk);
        end


        rst_n = 1'b1;


        /*
         * Scenario 0:
         *
         * EXEC-only masking.
         */
        exec_mask = '1;

        exec_mask[3] = 1'b0;
        exec_mask[9] = 1'b0;
        exec_mask[17] = 1'b0;
        exec_mask[31] = 1'b0;


        run_scenario(
            0,
            exec_mask,
            1'b0,
            '0
        );


        /*
         * Scenario 1:
         *
         * EXEC + predicate masking.
         */
        exec_mask = '1;

        exec_mask[5] = 1'b0;
        exec_mask[12] = 1'b0;
        exec_mask[24] = 1'b0;

        pred_mask = '0;


        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin

            /*
             * Deliberately non-power-of-two
             * predicate pattern.
             */
            if (
                (lane % 3) != 1
            ) begin

                pred_mask[lane] =
                    1'b1;
            end
        end


        run_scenario(
            1,
            exec_mask,
            1'b1,
            pred_mask
        );


        $fclose(
            result_file
        );


        $display(
            "RTL4A_TB=PASS physical=%0d beats=%0d",
            PHYSICAL_LANES,
            EXPECTED_BEATS
        );


        $finish;
    end

endmodule
