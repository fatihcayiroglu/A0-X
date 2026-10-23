`timescale 1ns/1ps

/* Bounded-cluster physical-store ordering metadata controller. */
module a0_cluster_store_order_controller #(
    parameter integer CU_COUNT = 4,
    parameter integer WAVE_SIZE = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer WAVE_ID_W = 2,
    parameter integer CONTEXT_ID_W = WAVE_ID_W,
    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W
) (
    input logic clk,
    input logic rst_n,

    input logic [CU_COUNT-1:0] store_launch_valid_i,
    input logic [WAVE_ID_W-1:0]
        store_launch_wave_i [0:CU_COUNT-1],
    input logic [CONTEXT_ID_W-1:0]
        store_launch_context_i [0:CU_COUNT-1],
    input logic [WAVE_SIZE-1:0]
        store_launch_lane_mask_i [0:CU_COUNT-1],
    input logic [31:0]
        store_launch_word_addr_i [0:CU_COUNT-1][0:WAVE_SIZE-1],

    input logic [CU_COUNT-1:0] store_terminal_valid_i,
    input logic [WAVE_ID_W-1:0]
        store_terminal_wave_i [0:CU_COUNT-1],
    input logic [CONTEXT_ID_W-1:0]
        store_terminal_context_i [0:CU_COUNT-1],
    input logic [CU_COUNT-1:0] store_terminal_fault_i,

    input logic [CU_COUNT-1:0] fabric_candidate_valid_i,
    input logic [LINE_ADDR_W-1:0]
        fabric_candidate_line_addr_i [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] fabric_peer_conflict_o,

    output logic [CU_COUNT-1:0] pending_store_valid_o,

    output logic [CU_COUNT-1:0] launch_observe_valid_o,
    output logic [WAVE_SIZE-1:0]
        launch_observe_lane_mask_o [0:CU_COUNT-1],
    output logic [31:0]
        launch_observe_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1],

    output logic [CU_COUNT-1:0] ordering_store_valid_o,
    output logic [WAVE_SIZE-1:0]
        ordering_store_lane_mask_o [0:CU_COUNT-1],
    output logic [31:0]
        ordering_store_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1],

    output logic [CU_COUNT-1:0] terminal_store_valid_o,
    output logic [CU_COUNT-1:0] terminal_store_fault_o,
    output logic [WAVE_SIZE-1:0]
        terminal_store_lane_mask_o [0:CU_COUNT-1],
    output logic [31:0]
        terminal_store_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1]
);
    localparam integer EXPECTED_WORD_SELECT_W = 3;
    localparam integer EXPECTED_LINE_ADDR_W = 29;

    logic [CU_COUNT-1:0] pending_valid_q;
    logic [WAVE_ID_W-1:0] pending_wave_q [0:CU_COUNT-1];
    logic [CONTEXT_ID_W-1:0] pending_context_q [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] pending_lane_mask_q [0:CU_COUNT-1];
    logic [31:0] pending_word_addr_q
        [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [CU_COUNT-1:0] terminal_match;

    integer cu;
    integer lane;
    integer target;
    integer source;
    integer reset_cu;
    integer reset_lane;
    integer capture_cu;
    integer capture_lane;

    function automatic logic [LINE_ADDR_W-1:0] word_to_line(
        input logic [31:0] word_addr
    );
        word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
    endfunction

    initial begin
        if (CU_COUNT < 1 || CU_COUNT > 4)
            $fatal(1, "cluster store controller supports CU_COUNT 1..4");
        if (WAVE_SIZE != 32)
            $fatal(1, "cluster store controller requires WAVE_SIZE=32");
        if (LINE_WORDS != 8)
            $fatal(1, "cluster store controller requires LINE_WORDS=8");
        if (WAVE_ID_W < 1 || CONTEXT_ID_W < 1)
            $fatal(1, "cluster store controller owner widths must be >=1");
        if (WORD_SELECT_W != EXPECTED_WORD_SELECT_W)
            $fatal(1, "cluster store controller WORD_SELECT_W inconsistent");
        if (LINE_ADDR_W != EXPECTED_LINE_ADDR_W)
            $fatal(1, "cluster store controller LINE_ADDR_W inconsistent");
    end

    always_comb begin
        terminal_match = '0;
        pending_store_valid_o = pending_valid_q;
        launch_observe_valid_o = store_launch_valid_i;
        ordering_store_valid_o = '0;
        terminal_store_valid_o = '0;
        terminal_store_fault_o = '0;

        for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin
            launch_observe_lane_mask_o[cu] =
                store_launch_lane_mask_i[cu];
            ordering_store_lane_mask_o[cu] = '0;
            terminal_store_lane_mask_o[cu] = '0;

            terminal_match[cu] =
                store_terminal_valid_i[cu]
                && pending_valid_q[cu]
                && store_terminal_wave_i[cu] == pending_wave_q[cu]
                && store_terminal_context_i[cu] == pending_context_q[cu];
            terminal_store_valid_o[cu] = terminal_match[cu];
            terminal_store_fault_o[cu] =
                terminal_match[cu] && store_terminal_fault_i[cu];

            if (store_launch_valid_i[cu]) begin
                ordering_store_valid_o[cu] = 1'b1;
                ordering_store_lane_mask_o[cu] =
                    store_launch_lane_mask_i[cu];
            end else if (pending_valid_q[cu]) begin
                ordering_store_valid_o[cu] = 1'b1;
                ordering_store_lane_mask_o[cu] = pending_lane_mask_q[cu];
            end

            if (terminal_match[cu]) begin
                terminal_store_lane_mask_o[cu] = pending_lane_mask_q[cu];
            end

            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                launch_observe_word_addr_o[cu][lane] =
                    store_launch_word_addr_i[cu][lane];
                ordering_store_word_addr_o[cu][lane] = '0;
                terminal_store_word_addr_o[cu][lane] = '0;

                if (store_launch_valid_i[cu]) begin
                    ordering_store_word_addr_o[cu][lane] =
                        store_launch_word_addr_i[cu][lane];
                end else if (pending_valid_q[cu]) begin
                    ordering_store_word_addr_o[cu][lane] =
                        pending_word_addr_q[cu][lane];
                end

                if (terminal_match[cu]) begin
                    terminal_store_word_addr_o[cu][lane] =
                        pending_word_addr_q[cu][lane];
                end
            end
        end

        /* This query has no ready input and cannot form a ready/valid loop. */
        fabric_peer_conflict_o = '0;
        for (target = 0; target < CU_COUNT; target = target + 1) begin
            if (fabric_candidate_valid_i[target]) begin
                for (source = 0; source < CU_COUNT; source = source + 1) begin
                    if (source != target && ordering_store_valid_o[source]) begin
                        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                            if (ordering_store_lane_mask_o[source][lane]
                                && word_to_line(
                                    ordering_store_word_addr_o[source][lane]
                                ) == fabric_candidate_line_addr_i[target]) begin
                                fabric_peer_conflict_o[target] = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pending_valid_q <= '0;
            for (reset_cu = 0; reset_cu < CU_COUNT;
                 reset_cu = reset_cu + 1) begin
                pending_wave_q[reset_cu] <= '0;
                pending_context_q[reset_cu] <= '0;
                pending_lane_mask_q[reset_cu] <= '0;
                for (reset_lane = 0; reset_lane < WAVE_SIZE;
                     reset_lane = reset_lane + 1) begin
                    pending_word_addr_q[reset_cu][reset_lane] <= '0;
                end
            end
        end else begin
            for (capture_cu = 0; capture_cu < CU_COUNT;
                 capture_cu = capture_cu + 1) begin
                if (terminal_match[capture_cu]) begin
                    pending_valid_q[capture_cu] <= 1'b0;
                    pending_lane_mask_q[capture_cu] <= '0;
                    for (capture_lane = 0; capture_lane < WAVE_SIZE;
                         capture_lane = capture_lane + 1) begin
                        pending_word_addr_q[capture_cu][capture_lane] <= '0;
                    end
                end
                /* Existing cores permit one physical store in flight. */
                if (store_launch_valid_i[capture_cu]
                    && (!pending_valid_q[capture_cu]
                        || terminal_match[capture_cu])) begin
                    pending_valid_q[capture_cu] <= 1'b1;
                    pending_wave_q[capture_cu] <=
                        store_launch_wave_i[capture_cu];
                    pending_context_q[capture_cu] <=
                        store_launch_context_i[capture_cu];
                    pending_lane_mask_q[capture_cu] <=
                        store_launch_lane_mask_i[capture_cu];
                    for (capture_lane = 0; capture_lane < WAVE_SIZE;
                         capture_lane = capture_lane + 1) begin
                        pending_word_addr_q[capture_cu][capture_lane] <=
                            store_launch_word_addr_i[capture_cu][capture_lane];
                    end
                end
            end
        end
    end
endmodule
