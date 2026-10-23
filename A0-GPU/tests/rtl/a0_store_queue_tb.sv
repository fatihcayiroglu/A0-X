`timescale 1ns/1ps

module a0_store_queue_tb;

    localparam integer STORE_QUEUE_DEPTH = 2;
    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer CONTEXT_ID_W = 2;
    localparam integer STORE_SEQ_W = 64;
    localparam integer OCCUPANCY_W = 2;

    logic clk;
    logic rst_n;

    logic enqueue_valid_i;
    logic enqueue_ready_o;
    logic enqueue_fire_o;
    logic [WAVE_ID_W-1:0] enqueue_wave_i;
    logic [CONTEXT_ID_W-1:0] enqueue_context_i;
    logic [STORE_SEQ_W-1:0] enqueue_seq_i;
    logic [WAVE_SIZE-1:0] enqueue_lane_mask_i;
    logic [31:0] enqueue_word_addr_i [0:WAVE_SIZE-1];
    logic [31:0] enqueue_wdata_i [0:WAVE_SIZE-1];

    logic drain_valid_o;
    logic drain_ready_i;
    logic drain_fire_o;
    logic [WAVE_ID_W-1:0] drain_wave_o;
    logic [CONTEXT_ID_W-1:0] drain_context_o;
    logic [STORE_SEQ_W-1:0] drain_seq_o;
    logic [WAVE_SIZE-1:0] drain_lane_mask_o;
    logic [31:0] drain_word_addr_o [0:WAVE_SIZE-1];
    logic [31:0] drain_wdata_o [0:WAVE_SIZE-1];

    logic probe_valid_i;
    logic [WAVE_SIZE-1:0] probe_lane_mask_i;
    logic [31:0] probe_word_addr_i [0:WAVE_SIZE-1];
    logic [STORE_SEQ_W-1:0] probe_seq_boundary_i;
    logic probe_conflict_o;
    logic [WAVE_SIZE-1:0] probe_conflict_lane_mask_o;
    logic probe_line_conflict_o;
    logic [WAVE_SIZE-1:0] probe_line_conflict_lane_mask_o;
    logic [WAVE_SIZE-1:0] probe_source_valid_lane_mask_o;
    logic [WAVE_SIZE-1:0] probe_source_ambiguous_lane_mask_o;
    logic [STORE_SEQ_W-1:0] probe_source_seq_o [0:WAVE_SIZE-1];
    logic [31:0] probe_source_wdata_o [0:WAVE_SIZE-1];

    logic [OCCUPANCY_W-1:0] occupancy_o;
    logic full_o;
    logic empty_o;
    logic [RESIDENT_WAVES-1:0] active_wave_mask_o;
    logic enqueue_stall_o;

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
        .drain_seq_o(drain_seq_o),
        .drain_lane_mask_o(drain_lane_mask_o),
        .drain_word_addr_o(drain_word_addr_o),
        .drain_wdata_o(drain_wdata_o),
        .probe_valid_i(probe_valid_i),
        .probe_lane_mask_i(probe_lane_mask_i),
        .probe_word_addr_i(probe_word_addr_i),
        .probe_seq_boundary_i(probe_seq_boundary_i),
        .probe_conflict_o(probe_conflict_o),
        .probe_conflict_lane_mask_o(probe_conflict_lane_mask_o),
        .probe_line_conflict_o(probe_line_conflict_o),
        .probe_line_conflict_lane_mask_o(
            probe_line_conflict_lane_mask_o
        ),
        .probe_source_valid_lane_mask_o(
            probe_source_valid_lane_mask_o
        ),
        .probe_source_ambiguous_lane_mask_o(
            probe_source_ambiguous_lane_mask_o
        ),
        .probe_source_seq_o(probe_source_seq_o),
        .probe_source_wdata_o(probe_source_wdata_o),
        .occupancy_o(occupancy_o),
        .full_o(full_o),
        .empty_o(empty_o),
        .active_wave_mask_o(active_wave_mask_o),
        .enqueue_stall_o(enqueue_stall_o)
    );

    task automatic drive_store(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [CONTEXT_ID_W-1:0] context_id,
        input integer address_base,
        input integer data_base
    );
        begin
            @(negedge clk);
            enqueue_wave_i = wave;
            enqueue_context_i = context_id;
            enqueue_seq_i = STORE_SEQ_W'(address_base);
            enqueue_lane_mask_i = '1;

            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                enqueue_word_addr_i[lane] = 32'(address_base + lane);
                enqueue_wdata_i[lane] = 32'(data_base + lane);
            end

            enqueue_valid_i = 1'b1;
            #1;

            if (!enqueue_ready_o || !enqueue_fire_o) begin
                $fatal(1, "expected enqueue ready/fire wave=%0d", wave);
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            enqueue_valid_i = 1'b0;
        end
    endtask

    task automatic expect_head(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [CONTEXT_ID_W-1:0] context_id,
        input integer address_base,
        input integer data_base
    );
        begin
            #1;
            if (!drain_valid_o) begin
                $fatal(1, "expected valid queue head");
            end
            if (
                drain_wave_o != wave
                || drain_context_o != context_id
                || drain_seq_o != STORE_SEQ_W'(address_base)
                || drain_lane_mask_o != '1
            ) begin
                $fatal(1, "queue head ownership mismatch");
            end

            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                if (drain_word_addr_o[lane] != 32'(address_base + lane)) begin
                    $fatal(1, "head address mismatch lane=%0d", lane);
                end
                if (drain_wdata_o[lane] != 32'(data_base + lane)) begin
                    $fatal(1, "head data mismatch lane=%0d", lane);
                end
            end
        end
    endtask

    task automatic pop_head;
        begin
            @(negedge clk);
            drain_ready_i = 1'b1;
            #1;
            if (!drain_fire_o) begin
                $fatal(1, "expected drain fire");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            drain_ready_i = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        enqueue_valid_i = 1'b0;
        enqueue_wave_i = '0;
        enqueue_context_i = '0;
        enqueue_seq_i = '0;
        enqueue_lane_mask_i = '0;
        drain_ready_i = 1'b0;
        probe_valid_i = 1'b0;
        probe_lane_mask_i = '0;
        probe_seq_boundary_i = '0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            enqueue_word_addr_i[lane] = '0;
            enqueue_wdata_i[lane] = '0;
            probe_word_addr_i[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (
            !empty_o
            || full_o
            || occupancy_o != 0
            || active_wave_mask_o != 0
            || drain_valid_o
        ) begin
            $fatal(1, "store queue reset state mismatch");
        end
        $display("RTL8C_STORE_QUEUE_RESET=PASS");

        drive_store(2'd0, 2'd0, 100, 1000);
        #1;

        if (
            occupancy_o != 1
            || active_wave_mask_o != 4'b0001
            || empty_o
            || full_o
        ) begin
            $fatal(1, "first enqueue state mismatch");
        end

        expect_head(2'd0, 2'd0, 100, 1000);
        $display("RTL8C_STORE_QUEUE_ENQUEUE_METADATA_DATA=PASS");

        @(negedge clk);
        enqueue_wave_i = 2'd0;
        enqueue_context_i = 2'd0;
        enqueue_lane_mask_i = '1;
        enqueue_valid_i = 1'b1;
        #1;

        if (enqueue_ready_o || enqueue_fire_o || !enqueue_stall_o) begin
            $fatal(1, "duplicate live wave store was not blocked");
        end

        enqueue_valid_i = 1'b0;
        $display("RTL8C_STORE_QUEUE_ACTIVE_WAVE_GUARD=PASS");

        drive_store(2'd1, 2'd1, 200, 2000);
        #1;

        if (
            occupancy_o != OCCUPANCY_W'(STORE_QUEUE_DEPTH)
            || !full_o
            || active_wave_mask_o != 4'b0011
        ) begin
            $fatal(1, "queue did not become full");
        end

        @(negedge clk);
        enqueue_wave_i = 2'd2;
        enqueue_context_i = 2'd2;
        enqueue_valid_i = 1'b1;
        #1;

        if (enqueue_ready_o || enqueue_fire_o || !enqueue_stall_o) begin
            $fatal(1, "full queue did not apply backpressure");
        end

        enqueue_valid_i = 1'b0;
        $display("RTL8C_STORE_QUEUE_FULL_BACKPRESSURE=PASS");

        @(negedge clk);
        probe_lane_mask_i = 4'b0011;
        probe_seq_boundary_i = STORE_SEQ_W'(150);
        probe_word_addr_i[0] = 32'd101;
        probe_word_addr_i[1] = 32'd999;
        probe_word_addr_i[2] = '0;
        probe_word_addr_i[3] = '0;
        probe_valid_i = 1'b1;
        #1;

        if (
            !probe_conflict_o
            || probe_conflict_lane_mask_o != 4'b0001
            || probe_source_valid_lane_mask_o != 4'b0001
            || probe_source_ambiguous_lane_mask_o != '0
            || probe_source_seq_o[0] != STORE_SEQ_W'(100)
            || probe_source_wdata_o[0] != 32'd1001
        ) begin
            $fatal(
                1,
                "conflict probe mismatch mask=%b",
                probe_conflict_lane_mask_o
            );
        end
        $display("RTL8C_STORE_QUEUE_CONFLICT_PROBE=PASS");

        @(negedge clk);
        probe_lane_mask_i = 4'b0001;
        probe_word_addr_i[0] = 32'd99;
        probe_valid_i = 1'b1;
        #1;

        if (
            probe_conflict_o
            || probe_conflict_lane_mask_o != '0
            || !probe_line_conflict_o
            || probe_line_conflict_lane_mask_o != 4'b0001
            || probe_source_valid_lane_mask_o != '0
            || probe_source_ambiguous_lane_mask_o != '0
        ) begin
            $fatal(1, "same-line/different-word probe mismatch");
        end

        $display("RTL8C_STORE_QUEUE_LINE_CONFLICT_PROBE=PASS");

        probe_valid_i = 1'b0;

        expect_head(2'd0, 2'd0, 100, 1000);
        pop_head();
        #1;

        if (
            occupancy_o != 1
            || full_o
            || active_wave_mask_o != 4'b0010
        ) begin
            $fatal(1, "first drain state mismatch");
        end

        expect_head(2'd1, 2'd1, 200, 2000);
        $display("RTL8C_STORE_QUEUE_FIFO_ORDER=PASS");

        drive_store(2'd0, 2'd0, 300, 3000);
        #1;

        if (
            occupancy_o != 2
            || active_wave_mask_o != 4'b0011
            || !full_o
        ) begin
            $fatal(1, "wave reuse enqueue mismatch");
        end
        $display("RTL8C_STORE_QUEUE_WAVE_REUSE_AFTER_DRAIN=PASS");

        expect_head(2'd1, 2'd1, 200, 2000);
        pop_head();
        expect_head(2'd0, 2'd0, 300, 3000);
        pop_head();
        #1;

        if (
            !empty_o
            || full_o
            || occupancy_o != 0
            || active_wave_mask_o != 0
            || drain_valid_o
        ) begin
            $fatal(1, "queue did not fully drain");
        end

        @(negedge clk);
        probe_lane_mask_i = 4'b0001;
        probe_word_addr_i[0] = 32'd300;
        probe_valid_i = 1'b1;
        #1;

        if (probe_conflict_o || probe_conflict_lane_mask_o != 0
            || probe_source_valid_lane_mask_o != '0
            || probe_source_ambiguous_lane_mask_o != '0
            || probe_source_seq_o[0] != '0
            || probe_source_wdata_o[0] != '0) begin
            $fatal(1, "drained queue still reported conflict/source");
        end

        probe_valid_i = 1'b0;

        $display("RTL8C_STORE_QUEUE_FINAL_DRAIN=PASS");
        $display("RTL8C_STORE_QUEUE_TB=PASS");
        $finish;
    end

endmodule
