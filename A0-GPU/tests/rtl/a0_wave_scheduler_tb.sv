`timescale 1ns/1ps

module a0_wave_scheduler_tb;

    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer WAVE_COUNT_W = 3;

    logic clk;
    logic rst_n;

    logic [3:0] ready_mask_i;
    logic [3:0] memory_ready_mask_i;
    logic [3:0] non_memory_ready_mask_i;
    logic [3:0] memory_stalled_mask_i;
    logic [3:0] merge_ready_mask_i;

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
    logic [3:0] merge_ready_visible_o;

    logic [WAVE_COUNT_W-1:0] ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] non_memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_stalled_count_o;
    logic [WAVE_COUNT_W-1:0] merge_ready_count_o;
    logic [WAVE_ID_W-1:0] rr_cursor_o;


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


    task automatic expect_grant(
        input logic expected_valid,
        input logic [WAVE_ID_W-1:0] expected_wave
    );
        begin
            #1;
            if (
                grant_valid_o != expected_valid
                || lrr_candidate_valid_o != expected_valid
            ) begin
                $fatal(
                    1,
                    "grant/LRR valid mismatch expected=%0d grant=%0d lrr=%0d",
                    expected_valid,
                    grant_valid_o,
                    lrr_candidate_valid_o
                );
            end

            if (
                expected_valid
                && lrr_candidate_wave_o != expected_wave
            ) begin
                $fatal(
                    1,
                    "LRR candidate mismatch expected=%0d actual=%0d cursor=%0d",
                    expected_wave,
                    lrr_candidate_wave_o,
                    rr_cursor_o
                );
            end

            if (
                expected_valid
                && grant_wave_o != expected_wave
            ) begin
                $fatal(
                    1,
                    "grant wave mismatch expected=%0d actual=%0d cursor=%0d",
                    expected_wave,
                    grant_wave_o,
                    rr_cursor_o
                );
            end
        end
    endtask


    task automatic fire_expected(
        input logic [WAVE_ID_W-1:0] expected_wave
    );
        begin
            grant_fire_i = 1'b1;
            expect_grant(1'b1, expected_wave);
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask


    initial begin
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

        ready_mask_i = 4'b1111;
        memory_ready_mask_i = 4'b0101;
        non_memory_ready_mask_i = 4'b1010;

        /*
         * Backpressure: cursor and selected wave must not advance without
         * grant_fire_i.
         */
        grant_fire_i = 1'b0;
        expect_grant(1'b1, 2'd0);
        repeat (3) begin
            @(posedge clk);
            #1;
            if (rr_cursor_o != 2'd0) begin
                $fatal(1, "LRR cursor moved without grant_fire");
            end
            @(negedge clk);
            expect_grant(1'b1, 2'd0);
        end

        $display("RTL7_SCHED_BACKPRESSURE_STABLE=PASS");

        /*
         * Four ready waves must rotate 0 -> 1 -> 2 -> 3 -> 0.
         */
        fire_expected(2'd0);
        fire_expected(2'd1);
        fire_expected(2'd2);
        fire_expected(2'd3);
        fire_expected(2'd0);

        grant_fire_i = 1'b0;
        $display("RTL7_SCHED_LRR_FAIRNESS=PASS");

        /*
         * Cursor is now 1. Wave 1 is blocked in ready_mask, so LRR must skip
         * directly to wave 2.
         */
        ready_mask_i = 4'b1101;
        expect_grant(1'b1, 2'd2);

        grant_fire_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        grant_fire_i = 1'b0;

        if (rr_cursor_o != 2'd3) begin
            $fatal(1, "LRR cursor did not advance after skip grant");
        end

        $display("RTL7_SCHED_SKIP_BLOCKED=PASS");

        /*
         * Override acceptance and fallback.
         */
        ready_mask_i = 4'b1111;
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd3;

        #1;
        if (
            !policy_override_accepted_o
            || grant_wave_o != 2'd3
        ) begin
            $fatal(1, "ready override was not accepted");
        end

        grant_fire_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        grant_fire_i = 1'b0;

        if (rr_cursor_o != 2'd0) begin
            $fatal(1, "override grant did not update LRR cursor");
        end

        ready_mask_i = 4'b0101;
        policy_override_wave_i = 2'd1;
        #1;

        if (
            policy_override_accepted_o
            || !grant_valid_o
            || grant_wave_o != 2'd0
        ) begin
            $fatal(1, "unready override did not fall back to LRR");
        end

        $display("RTL7_SCHED_POLICY_HOOK=PASS");

        /*
         * Pressure and policy metadata telemetry.
         */
        ready_mask_i = 4'b1111;
        memory_ready_mask_i = 4'b0111;
        non_memory_ready_mask_i = 4'b1000;
        memory_stalled_mask_i = 4'b1010;
        merge_ready_mask_i = 4'b0101;

        mshr_occupancy_i = 8'd2;
        mshr_capacity_i = 8'd4;

        #1;
        if (
            !pressure_high_o
            || merge_ready_visible_o != 4'b0101
            || ready_count_o != 3'd4
            || memory_ready_count_o != 3'd3
            || non_memory_ready_count_o != 3'd1
            || memory_stalled_count_o != 3'd2
            || merge_ready_count_o != 3'd2
        ) begin
            $fatal(1, "policy telemetry mismatch at high pressure");
        end

        mshr_occupancy_i = 8'd1;
        #1;
        if (pressure_high_o) begin
            $fatal(1, "pressure high asserted below 50 percent");
        end

        mshr_capacity_i = 8'd0;
        mshr_occupancy_i = 8'd7;
        #1;
        if (pressure_high_o) begin
            $fatal(1, "zero-capacity pressure should be false");
        end

        $display("RTL7_SCHED_PRESSURE_TELEMETRY=PASS");

        /*
         * No-ready case.
         */
        policy_override_valid_i = 1'b0;
        ready_mask_i = 4'b0000;
        #1;

        if (
            grant_valid_o
            || lrr_candidate_valid_o
        ) begin
            $fatal(1, "scheduler granted with no ready wave");
        end

        $display("RTL7_SCHED_EMPTY=PASS");
        $display("RTL7_WAVE_SCHEDULER_TB=PASS");

        $finish;
    end

endmodule
