`timescale 1ns/1ps

module a0_store_queue_rtl8c5_age_tb;

    localparam integer STORE_QUEUE_DEPTH = 4;
    localparam integer RESIDENT_WAVES = 8;
    localparam integer WAVE_SIZE = 4;
    localparam integer STORE_SEQ_W = 64;
    localparam integer WAVE_ID_W = 3;
    localparam integer OCCUPANCY_W = 3;

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
        .probe_line_conflict_lane_mask_o(probe_line_conflict_lane_mask_o),
        .probe_source_valid_lane_mask_o(probe_source_valid_lane_mask_o),
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

    task automatic clear_payload;
        begin
            enqueue_lane_mask_i = '0;
            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                enqueue_word_addr_i[lane] = '0;
                enqueue_wdata_i[lane] = '0;
            end
        end
    endtask

    task automatic enqueue_single(
        input logic [STORE_SEQ_W-1:0] seq,
        input logic [WAVE_ID_W-1:0] wave,
        input logic [31:0] word_addr,
        input logic [31:0] wdata
    );
        begin
            @(negedge clk);
            clear_payload();
            enqueue_wave_i = wave;
            enqueue_context_i = wave;
            enqueue_seq_i = seq;
            enqueue_lane_mask_i = 4'b0001;
            enqueue_word_addr_i[0] = word_addr;
            enqueue_wdata_i[0] = wdata;
            enqueue_valid_i = 1'b1;
            #1;
            if (!enqueue_ready_o || !enqueue_fire_o || enqueue_stall_o) begin
                $fatal(1, "age-source enqueue failed seq=%0d", seq);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            enqueue_valid_i = 1'b0;
        end
    endtask

    task automatic enqueue_duplicate(
        input logic [STORE_SEQ_W-1:0] seq,
        input logic [WAVE_ID_W-1:0] wave,
        input logic [31:0] word_addr
    );
        begin
            @(negedge clk);
            clear_payload();
            enqueue_wave_i = wave;
            enqueue_context_i = wave;
            enqueue_seq_i = seq;
            enqueue_lane_mask_i = 4'b0011;
            enqueue_word_addr_i[0] = word_addr;
            enqueue_word_addr_i[1] = word_addr;
            enqueue_wdata_i[0] = 32'd4000;
            enqueue_wdata_i[1] = 32'd4001;
            enqueue_valid_i = 1'b1;
            #1;
            if (!enqueue_ready_o || !enqueue_fire_o || enqueue_stall_o) begin
                $fatal(1, "duplicate-source enqueue failed seq=%0d", seq);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            enqueue_valid_i = 1'b0;
        end
    endtask

    task automatic probe_word(
        input logic [31:0] word_addr,
        input logic [STORE_SEQ_W-1:0] boundary
    );
        begin
            @(negedge clk);
            probe_valid_i = 1'b1;
            probe_lane_mask_i = 4'b0001;
            probe_word_addr_i[0] = word_addr;
            probe_seq_boundary_i = boundary;
            #1;
        end
    endtask

    task automatic pop_expect_seq(
        input logic [STORE_SEQ_W-1:0] seq,
        input logic [WAVE_ID_W-1:0] wave,
        input logic [WAVE_SIZE-1:0] lane_mask,
        input logic [31:0] word_addr0,
        input logic [31:0] wdata0
    );
        begin
            #1;
            if (!drain_valid_o || drain_seq_o != seq
                || drain_wave_o != wave || drain_context_o != wave
                || drain_lane_mask_o != lane_mask
                || drain_word_addr_o[0] != word_addr0
                || drain_wdata_o[0] != wdata0) begin
                $fatal(
                    1,
                    "drain sequence mismatch expected=%0d got=%0d valid=%0b",
                    seq,
                    drain_seq_o,
                    drain_valid_o
                );
            end
            @(negedge clk);
            drain_ready_i = 1'b1;
            #1;
            if (!drain_fire_o) begin
                $fatal(1, "expected drain fire seq=%0d", seq);
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
        clear_payload();
        drain_ready_i = 1'b0;
        probe_valid_i = 1'b0;
        probe_lane_mask_i = '0;
        probe_seq_boundary_i = '0;
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            probe_word_addr_i[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        enqueue_single(64'd10, 3'd0, 32'd100, 32'd1000);
        enqueue_single(64'd11, 3'd1, 32'd100, 32'd2000);
        enqueue_single(64'd12, 3'd2, 32'd100, 32'd3000);
        enqueue_duplicate(64'd13, 3'd3, 32'd400);

        if (!full_o || occupancy_o != 3'd4
            || active_wave_mask_o != 8'b0000_1111) begin
            $fatal(1, "age-source queue did not fill");
        end

        /* seq=12 is equal to the exclusive boundary and must be ignored. */
        probe_word(32'd100, 64'd12);
        if (
            !probe_conflict_o
            || probe_conflict_lane_mask_o != 4'b0001
            || !probe_line_conflict_o
            || probe_line_conflict_lane_mask_o != 4'b0001
            || probe_source_valid_lane_mask_o != 4'b0001
            || probe_source_ambiguous_lane_mask_o != '0
            || probe_source_seq_o[0] != 64'd11
            || probe_source_wdata_o[0] != 32'd2000
        ) begin
            $fatal(1, "youngest older source mismatch at boundary 12");
        end
        $display("RTL8C5_PROBE_IGNORES_YOUNGER_STORE=PASS");
        $display("RTL8C5_PROBE_SELECTS_YOUNGEST_OLDER=PASS");

        /* Tighten the boundary: seq=11 is now younger/equal and seq=10 wins. */
        probe_word(32'd100, 64'd11);
        if (
            !probe_conflict_o
            || probe_conflict_lane_mask_o != 4'b0001
            || !probe_line_conflict_o
            || probe_line_conflict_lane_mask_o != 4'b0001
            || probe_source_valid_lane_mask_o != 4'b0001
            || probe_source_ambiguous_lane_mask_o != '0
            || probe_source_seq_o[0] != 64'd10
            || probe_source_wdata_o[0] != 32'd1000
        ) begin
            $fatal(1, "exclusive age boundary mismatch at boundary 11");
        end

        probe_word(32'd400, 64'd14);
        if (
            !probe_conflict_o
            || probe_conflict_lane_mask_o != 4'b0001
            || !probe_line_conflict_o
            || probe_line_conflict_lane_mask_o != 4'b0001
            || probe_source_valid_lane_mask_o != 4'b0001
            || probe_source_ambiguous_lane_mask_o != 4'b0001
            || probe_source_seq_o[0] != 64'd13
        ) begin
            $fatal(1, "duplicate store source was not marked ambiguous");
        end
        $display("RTL8C5_DUPLICATE_STORE_SOURCE_AMBIGUOUS=PASS");

        probe_valid_i = 1'b0;
        pop_expect_seq(64'd10, 3'd0, 4'b0001, 32'd100, 32'd1000);
        pop_expect_seq(64'd11, 3'd1, 4'b0001, 32'd100, 32'd2000);
        pop_expect_seq(64'd12, 3'd2, 4'b0001, 32'd100, 32'd3000);
        pop_expect_seq(64'd13, 3'd3, 4'b0011, 32'd400, 32'd4000);

        if (!empty_o || occupancy_o != '0 || active_wave_mask_o != '0) begin
            $fatal(1, "age-source queue did not drain");
        end

        $display("RTL8C5_QUEUE_SEQUENCE_ORDER=PASS");
        $display("RTL8C5_STORE_QUEUE_AGE_SOURCE_TB=PASS");
        $finish;
    end

endmodule
