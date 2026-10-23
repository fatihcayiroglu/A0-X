`timescale 1ns/1ps

/*
 * RTL8C behavioral parameterization test for a0_store_queue.
 *
 * The runner overrides STORE_QUEUE_DEPTH across 1,2,3,4,5,8,16.
 * This is behavioral, not lint-only: fill/full, FIFO data/ownership,
 * pointer wrap, occupancy, and simultaneous enqueue/drain are exercised.
 */
module a0_store_queue_capacity_tb #(
    parameter integer STORE_QUEUE_DEPTH = 3,
    parameter integer RESIDENT_WAVES = 32,
    parameter integer WAVE_SIZE = 2,
    parameter integer STORE_SEQ_W = 64,
    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer OCCUPANCY_W =
        (STORE_QUEUE_DEPTH <= 1)
            ? 1
            : $clog2(STORE_QUEUE_DEPTH + 1)
);

    logic clk;
    logic rst_n;

    logic enqueue_valid_i;
    logic enqueue_ready_o;
    logic enqueue_fire_o;
    logic [WAVE_ID_W-1:0] enqueue_wave_i;
    logic [WAVE_ID_W-1:0] enqueue_context_i;
    logic [STORE_SEQ_W-1:0] enqueue_seq_i;
    logic [WAVE_SIZE-1:0] enqueue_lane_mask_i;
    logic [31:0] enqueue_word_addr_i [0:WAVE_SIZE-1];
    logic [31:0] enqueue_wdata_i [0:WAVE_SIZE-1];

    logic drain_valid_o;
    logic drain_ready_i;
    logic drain_fire_o;
    logic [WAVE_ID_W-1:0] drain_wave_o;
    logic [WAVE_ID_W-1:0] drain_context_o;
    logic [STORE_SEQ_W-1:0] drain_seq_unused;
    logic [WAVE_SIZE-1:0] drain_lane_mask_o;
    logic [31:0] drain_word_addr_o [0:WAVE_SIZE-1];
    logic [31:0] drain_wdata_o [0:WAVE_SIZE-1];

    logic probe_conflict_o;
    logic [WAVE_SIZE-1:0] probe_conflict_lane_mask_o;
    logic probe_line_conflict_unused;
    logic [WAVE_SIZE-1:0]
        probe_line_conflict_lane_mask_unused;
    logic [WAVE_SIZE-1:0] probe_source_valid_unused;
    logic [WAVE_SIZE-1:0] probe_source_ambiguous_unused;
    logic [STORE_SEQ_W-1:0] probe_source_seq_unused [0:WAVE_SIZE-1];
    logic [31:0] probe_source_wdata_unused [0:WAVE_SIZE-1];
    logic [OCCUPANCY_W-1:0] occupancy_o;
    logic full_o;
    logic empty_o;
    logic [RESIDENT_WAVES-1:0] active_wave_mask_o;
    logic enqueue_stall_o;

    logic [RESIDENT_WAVES-1:0] expected_active;

    integer i;
    integer lane;

    always #5 clk = ~clk;

    a0_store_queue #(
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .STORE_SEQ_W(STORE_SEQ_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .enqueue_valid_i(enqueue_valid_i),
        .enqueue_ready_o(enqueue_ready_o),
        .enqueue_fire_o(enqueue_fire_o),
        .enqueue_wave_i(enqueue_wave_i),
        .enqueue_context_i(enqueue_context_i),
        .enqueue_seq_i(enqueue_seq_i),
        .enqueue_lane_mask_i(enqueue_lane_mask_i),
        .enqueue_word_addr_i(enqueue_word_addr_i),
        .enqueue_wdata_i(enqueue_wdata_i),

        .drain_valid_o(drain_valid_o),
        .drain_ready_i(drain_ready_i),
        .drain_fire_o(drain_fire_o),
        .drain_wave_o(drain_wave_o),
        .drain_context_o(drain_context_o),
        .drain_seq_o(drain_seq_unused),
        .drain_lane_mask_o(drain_lane_mask_o),
        .drain_word_addr_o(drain_word_addr_o),
        .drain_wdata_o(drain_wdata_o),

        .probe_valid_i(1'b0),
        .probe_lane_mask_i('0),
        .probe_word_addr_i(enqueue_word_addr_i),
        .probe_seq_boundary_i('0),
        .probe_conflict_o(probe_conflict_o),
        .probe_conflict_lane_mask_o(probe_conflict_lane_mask_o),
        .probe_line_conflict_o(probe_line_conflict_unused),
        .probe_line_conflict_lane_mask_o(
            probe_line_conflict_lane_mask_unused
        ),
        .probe_source_valid_lane_mask_o(probe_source_valid_unused),
        .probe_source_ambiguous_lane_mask_o(
            probe_source_ambiguous_unused
        ),
        .probe_source_seq_o(probe_source_seq_unused),
        .probe_source_wdata_o(probe_source_wdata_unused),

        .occupancy_o(occupancy_o),
        .full_o(full_o),
        .empty_o(empty_o),
        .active_wave_mask_o(active_wave_mask_o),
        .enqueue_stall_o(enqueue_stall_o)
    );

    task automatic set_payload(
        input integer wave,
        input integer base
    );
        integer payload_lane;
        begin
            if (wave < 0 || wave >= RESIDENT_WAVES)
                $fatal(1, "payload wave index out of range: %0d", wave);
            enqueue_wave_i = WAVE_ID_W'(wave);
            enqueue_context_i = WAVE_ID_W'(wave);
            enqueue_seq_i = STORE_SEQ_W'(base);
            enqueue_lane_mask_i = '1;

            for (
                payload_lane = 0;
                payload_lane < WAVE_SIZE;
                payload_lane = payload_lane + 1
            ) begin
                enqueue_word_addr_i[payload_lane] =
                    32'(base + payload_lane);
                enqueue_wdata_i[payload_lane] =
                    32'(100000 + base + payload_lane);
            end
        end
    endtask

    task automatic enqueue_one(
        input integer wave,
        input integer base
    );
        begin
            @(negedge clk);
            set_payload(wave, base);
            enqueue_valid_i = 1'b1;
            #1;

            if (!enqueue_ready_o || !enqueue_fire_o) begin
                $fatal(
                    1,
                    "enqueue blocked depth=%0d wave=%0d occ=%0d",
                    STORE_QUEUE_DEPTH,
                    wave,
                    occupancy_o
                );
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            enqueue_valid_i = 1'b0;
        end
    endtask

    task automatic expect_head(
        input integer wave,
        input integer base
    );
        integer head_lane;
        begin
            #1;

            if (!drain_valid_o) begin
                $fatal(1, "expected queue head depth=%0d", STORE_QUEUE_DEPTH);
            end

            if (
                drain_wave_o != WAVE_ID_W'(wave)
                || drain_context_o != WAVE_ID_W'(wave)
                || drain_lane_mask_o != '1
            ) begin
                $fatal(
                    1,
                    "head ownership mismatch depth=%0d expected=%0d got=%0d",
                    STORE_QUEUE_DEPTH,
                    wave,
                    drain_wave_o
                );
            end

            for (
                head_lane = 0;
                head_lane < WAVE_SIZE;
                head_lane = head_lane + 1
            ) begin
                if (
                    drain_word_addr_o[head_lane]
                    != 32'(base + head_lane)
                ) begin
                    $fatal(1, "head address mismatch");
                end
                if (
                    drain_wdata_o[head_lane]
                    != 32'(100000 + base + head_lane)
                ) begin
                    $fatal(1, "head data mismatch");
                end
            end
        end
    endtask

    task automatic drain_one;
        begin
            @(negedge clk);
            drain_ready_i = 1'b1;
            #1;
            if (!drain_fire_o) begin
                $fatal(1, "expected drain fire depth=%0d", STORE_QUEUE_DEPTH);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            drain_ready_i = 1'b0;
        end
    endtask

    initial begin
        if (
            STORE_QUEUE_DEPTH < 1
            || (2 * STORE_QUEUE_DEPTH) > RESIDENT_WAVES
        ) begin
            $fatal(
                1,
                "invalid capacity parameters depth=%0d waves=%0d",
                STORE_QUEUE_DEPTH,
                RESIDENT_WAVES
            );
        end

        clk = 1'b0;
        rst_n = 1'b0;
        enqueue_valid_i = 1'b0;
        enqueue_wave_i = '0;
        enqueue_context_i = '0;
        enqueue_lane_mask_i = '0;
        drain_ready_i = 1'b0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            enqueue_word_addr_i[lane] = '0;
            enqueue_wdata_i[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (
            !empty_o
            || full_o
            || occupancy_o != '0
            || active_wave_mask_o != '0
            || probe_conflict_o
            || probe_conflict_lane_mask_o != '0
        ) begin
            $fatal(1, "capacity reset mismatch");
        end

        expected_active = '0;
        for (i = 0; i < STORE_QUEUE_DEPTH; i = i + 1) begin
            enqueue_one(i, 1000 + (i * 16));
            expected_active[i] = 1'b1;
        end

        #1;
        if (
            !full_o
            || occupancy_o != OCCUPANCY_W'(STORE_QUEUE_DEPTH)
            || active_wave_mask_o != expected_active
        ) begin
            $fatal(1, "capacity full mismatch");
        end
        $display(
            "RTL8C_STORE_QUEUE_CAPACITY_FILL=PASS depth=%0d",
            STORE_QUEUE_DEPTH
        );

        @(negedge clk);
        set_payload(STORE_QUEUE_DEPTH, 1800);
        enqueue_valid_i = 1'b1;
        #1;
        if (enqueue_ready_o || enqueue_fire_o || !enqueue_stall_o) begin
            $fatal(1, "full replacement policy violated");
        end
        enqueue_valid_i = 1'b0;

        for (i = 0; i < STORE_QUEUE_DEPTH; i = i + 1) begin
            expect_head(i, 1000 + (i * 16));
            drain_one();
        end

        if (!empty_o || occupancy_o != '0 || active_wave_mask_o != '0) begin
            $fatal(1, "first capacity drain mismatch");
        end

        expected_active = '0;
        for (i = 0; i < STORE_QUEUE_DEPTH; i = i + 1) begin
            enqueue_one(
                STORE_QUEUE_DEPTH + i,
                3000 + (i * 16)
            );
            expected_active[STORE_QUEUE_DEPTH + i] = 1'b1;
        end

        if (
            !full_o
            || occupancy_o != OCCUPANCY_W'(STORE_QUEUE_DEPTH)
            || active_wave_mask_o != expected_active
        ) begin
            $fatal(1, "wrapped refill mismatch");
        end

        for (i = 0; i < STORE_QUEUE_DEPTH; i = i + 1) begin
            expect_head(
                STORE_QUEUE_DEPTH + i,
                3000 + (i * 16)
            );
            drain_one();
        end

        if (!empty_o || occupancy_o != '0 || active_wave_mask_o != '0) begin
            $fatal(1, "wrapped final drain mismatch");
        end
        $display(
            "RTL8C_STORE_QUEUE_POINTER_WRAP=PASS depth=%0d",
            STORE_QUEUE_DEPTH
        );

        enqueue_one(0, 5000);

        @(negedge clk);
        drain_ready_i = 1'b1;
        set_payload(1, 6000);
        enqueue_valid_i = 1'b1;
        #1;

        if (!drain_fire_o) begin
            $fatal(1, "simultaneous test missing drain");
        end

        if (STORE_QUEUE_DEPTH == 1) begin
            if (enqueue_ready_o || enqueue_fire_o) begin
                $fatal(1, "depth1 accepted full replacement");
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            drain_ready_i = 1'b0;
            enqueue_valid_i = 1'b0;

            if (!empty_o || occupancy_o != '0) begin
                $fatal(1, "depth1 replacement drain mismatch");
            end

            enqueue_one(1, 6000);

        end else begin
            if (!enqueue_ready_o || !enqueue_fire_o) begin
                $fatal(1, "simultaneous enqueue blocked");
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            drain_ready_i = 1'b0;
            enqueue_valid_i = 1'b0;

            if (occupancy_o != OCCUPANCY_W'(1)) begin
                $fatal(1, "simultaneous count mismatch");
            end
        end

        expect_head(1, 6000);
        drain_one();

        if (!empty_o || occupancy_o != '0 || active_wave_mask_o != '0) begin
            $fatal(1, "simultaneous final drain mismatch");
        end

        $display(
            "RTL8C_STORE_QUEUE_SIMULTANEOUS_HANDSHAKE=PASS depth=%0d",
            STORE_QUEUE_DEPTH
        );
        $display(
            "RTL8C_STORE_QUEUE_CAPACITY_TB=PASS depth=%0d",
            STORE_QUEUE_DEPTH
        );
        $finish;
    end

endmodule
