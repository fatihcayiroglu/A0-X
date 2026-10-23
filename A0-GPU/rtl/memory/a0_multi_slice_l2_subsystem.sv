`timescale 1ns/1ps

/*
 * A0 sliced-L2 subsystem foundation.
 *
 * Composes a0_line_slice_fabric with independent a0_l2_line_cache instances.
 * Each slice has an independent backend line interface, forming the clean
 * future memory-partition boundary. Store observations are routed only to the
 * deterministic home slice for each active store lane.
 *
 * This module remains isolated from a0_cu_cluster in this milestone.
 */
module a0_multi_slice_l2_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer STORE_LANES_PER_CLIENT = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer L2_SET_COUNT_PER_SLICE = 256,
    parameter integer L2_MISS_COUNT_PER_SLICE = 16,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,

    parameter integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),

    parameter integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W,

    parameter integer SLICE_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT),

    parameter integer SLICE_HASH_SHIFT =
        (L2_SET_COUNT_PER_SLICE <= 1)
            ? 0
            : $clog2(L2_SET_COUNT_PER_SLICE)
) (
    input logic clk,
    input logic rst_n,

    input logic [CLIENT_COUNT-1:0]
        client_req_valid_i,

    output logic [CLIENT_COUNT-1:0]
        client_req_ready_o,

    input logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i [0:CLIENT_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i [0:CLIENT_COUNT-1],

    output logic [CLIENT_COUNT-1:0]
        client_resp_valid_o,

    output logic [LOCAL_TAG_W-1:0]
        client_resp_local_tag_o [0:CLIENT_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        client_resp_line_addr_o [0:CLIENT_COUNT-1],

    output logic
        client_resp_fault_o [0:CLIENT_COUNT-1],

    output logic [31:0]
        client_resp_data_o
            [0:CLIENT_COUNT-1]
            [0:LINE_WORDS-1],

    input logic [CLIENT_COUNT-1:0]
        client_store_valid_i,

    input logic [STORE_LANES_PER_CLIENT-1:0]
        client_store_lane_mask_i [0:CLIENT_COUNT-1],

    input logic [31:0]
        client_store_word_addr_i
            [0:CLIENT_COUNT-1]
            [0:STORE_LANES_PER_CLIENT-1],

    output logic [L2_SLICE_COUNT-1:0]
        line_mem_req_valid_o,

    input logic [L2_SLICE_COUNT-1:0]
        line_mem_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        line_mem_req_global_tag_o [0:L2_SLICE_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1],

    input logic [L2_SLICE_COUNT-1:0]
        line_mem_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        line_mem_resp_global_tag_i [0:L2_SLICE_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1],

    input logic
        line_mem_resp_fault_i [0:L2_SLICE_COUNT-1],

    input logic [31:0]
        line_mem_resp_data_i
            [0:L2_SLICE_COUNT-1]
            [0:LINE_WORDS-1],

    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o
);

    localparam integer STORE_LANES =
        CLIENT_COUNT * STORE_LANES_PER_CLIENT;

    logic [L2_SLICE_COUNT-1:0]
        slice_req_valid;

    logic [L2_SLICE_COUNT-1:0]
        slice_req_ready;

    logic [GLOBAL_TAG_W-1:0]
        slice_req_global_tag [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_req_line_addr [0:L2_SLICE_COUNT-1];

    logic [L2_SLICE_COUNT-1:0]
        slice_resp_valid;

    logic [GLOBAL_TAG_W-1:0]
        slice_resp_global_tag [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_resp_line_addr [0:L2_SLICE_COUNT-1];

    logic
        slice_resp_fault [0:L2_SLICE_COUNT-1];

    logic [31:0]
        slice_resp_data
            [0:L2_SLICE_COUNT-1]
            [0:LINE_WORDS-1];

    logic [L2_SLICE_COUNT-1:0]
        slice_store_valid;

    logic [STORE_LANES-1:0]
        slice_store_lane_mask [0:L2_SLICE_COUNT-1];

    logic [31:0]
        slice_store_word_addr
            [0:L2_SLICE_COUNT-1]
            [0:STORE_LANES-1];

    integer route_slice;
    integer route_client;
    integer route_lane;
    integer route_flat_lane;


    function automatic logic [LINE_ADDR_W-1:0] word_to_line(
        input logic [31:0] word_addr
    );
        begin
            if (LINE_WORDS <= 1) begin
                word_to_line = word_addr[LINE_ADDR_W-1:0];
            end else begin
                word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
            end
        end
    endfunction


    function automatic logic [SLICE_ID_W-1:0] line_to_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (L2_SLICE_COUNT <= 1) begin
                line_to_slice = '0;
            end else begin
                low_bits = SLICE_ID_W'(line_addr);
                high_bits = SLICE_ID_W'(
                    line_addr >> SLICE_HASH_SHIFT
                );
                line_to_slice = low_bits ^ high_bits;
            end
        end
    endfunction


    initial begin
        if (CLIENT_COUNT < 1) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM CLIENT_COUNT must be >= 1");
        end
        if (LOCAL_TAG_W < 1) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM LOCAL_TAG_W must be >= 1");
        end
        if (STORE_LANES_PER_CLIENT < 1) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM STORE_LANES_PER_CLIENT must be >= 1");
        end
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM LINE_WORDS must be power of two");
        end
        if (
            L2_SLICE_COUNT < 1
            || (L2_SLICE_COUNT & (L2_SLICE_COUNT - 1)) != 0
        ) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM L2_SLICE_COUNT must be power of two");
        end
        if (
            L2_SET_COUNT_PER_SLICE < 1
            || (
                L2_SET_COUNT_PER_SLICE
                & (L2_SET_COUNT_PER_SLICE - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "SLICED_L2_SUBSYSTEM L2_SET_COUNT_PER_SLICE must be power of two"
            );
        end
        if (L2_MISS_COUNT_PER_SLICE < 1) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM L2_MISS_COUNT_PER_SLICE must be >= 1");
        end
        if (CLIENT_MAX_OUTSTANDING < 1) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM CLIENT_MAX_OUTSTANDING must be >= 1");
        end
    end


    always_comb begin
        for (
            route_slice = 0;
            route_slice < L2_SLICE_COUNT;
            route_slice = route_slice + 1
        ) begin
            slice_store_valid[route_slice] = 1'b0;
            slice_store_lane_mask[route_slice] = '0;

            for (
                route_flat_lane = 0;
                route_flat_lane < STORE_LANES;
                route_flat_lane = route_flat_lane + 1
            ) begin
                slice_store_word_addr[
                    route_slice
                ][route_flat_lane] = '0;
            end
        end

        for (
            route_client = 0;
            route_client < CLIENT_COUNT;
            route_client = route_client + 1
        ) begin
            for (
                route_lane = 0;
                route_lane < STORE_LANES_PER_CLIENT;
                route_lane = route_lane + 1
            ) begin
                route_flat_lane =
                    route_client * STORE_LANES_PER_CLIENT + route_lane;

                for (
                    route_slice = 0;
                    route_slice < L2_SLICE_COUNT;
                    route_slice = route_slice + 1
                ) begin
                    slice_store_word_addr[
                        route_slice
                    ][route_flat_lane] =
                        client_store_word_addr_i[
                            route_client
                        ][route_lane];

                    if (
                        client_store_valid_i[route_client]
                        && client_store_lane_mask_i[
                            route_client
                        ][route_lane]
                        && integer'(
                            line_to_slice(
                                word_to_line(
                                    client_store_word_addr_i[
                                        route_client
                                    ][route_lane]
                                )
                            )
                        ) == route_slice
                    ) begin
                        slice_store_lane_mask[
                            route_slice
                        ][route_flat_lane] = 1'b1;
                        slice_store_valid[route_slice] = 1'b1;
                    end
                end
            end
        end
    end


    a0_line_slice_fabric #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(L2_SLICE_COUNT),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .CLIENT_ID_W(CLIENT_ID_W),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .SLICE_ID_W(SLICE_ID_W)
    ) u_slice_fabric (
        .clk(clk),
        .rst_n(rst_n),

        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),

        .slice_req_valid_o(slice_req_valid),
        .slice_req_ready_i(slice_req_ready),
        .slice_req_global_tag_o(slice_req_global_tag),
        .slice_req_line_addr_o(slice_req_line_addr),

        .slice_resp_valid_i(slice_resp_valid),
        .slice_resp_global_tag_i(slice_resp_global_tag),
        .slice_resp_line_addr_i(slice_resp_line_addr),
        .slice_resp_fault_i(slice_resp_fault),
        .slice_resp_data_i(slice_resp_data),

        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),

        .line_resp_tag_error_o(line_resp_tag_error_o),
        .line_resp_overflow_o(line_resp_overflow_o)
    );


    generate
        genvar slice_gen;
        for (
            slice_gen = 0;
            slice_gen < L2_SLICE_COUNT;
            slice_gen = slice_gen + 1
        ) begin : g_l2_slice
            a0_l2_line_cache #(
                .STORE_LANES(STORE_LANES),
                .LINE_WORDS(LINE_WORDS),
                .SET_COUNT(L2_SET_COUNT_PER_SLICE),
                .GLOBAL_TAG_W(GLOBAL_TAG_W),
                .MISS_COUNT(L2_MISS_COUNT_PER_SLICE)
            ) u_l2 (
                .clk(clk),
                .rst_n(rst_n),

                .line_req_valid_i(slice_req_valid[slice_gen]),
                .line_req_ready_o(slice_req_ready[slice_gen]),
                .line_req_global_tag_i(slice_req_global_tag[slice_gen]),
                .line_req_line_addr_i(slice_req_line_addr[slice_gen]),

                .line_mem_req_valid_o(line_mem_req_valid_o[slice_gen]),
                .line_mem_req_ready_i(line_mem_req_ready_i[slice_gen]),
                .line_mem_req_global_tag_o(
                    line_mem_req_global_tag_o[slice_gen]
                ),
                .line_mem_req_line_addr_o(
                    line_mem_req_line_addr_o[slice_gen]
                ),

                .line_mem_resp_valid_i(line_mem_resp_valid_i[slice_gen]),
                .line_mem_resp_global_tag_i(
                    line_mem_resp_global_tag_i[slice_gen]
                ),
                .line_mem_resp_line_addr_i(
                    line_mem_resp_line_addr_i[slice_gen]
                ),
                .line_mem_resp_fault_i(line_mem_resp_fault_i[slice_gen]),
                .line_mem_resp_data_i(line_mem_resp_data_i[slice_gen]),

                .line_resp_valid_o(slice_resp_valid[slice_gen]),
                .line_resp_global_tag_o(slice_resp_global_tag[slice_gen]),
                .line_resp_line_addr_o(slice_resp_line_addr[slice_gen]),
                .line_resp_fault_o(slice_resp_fault[slice_gen]),
                .line_resp_data_o(slice_resp_data[slice_gen]),

                .store_valid_i(slice_store_valid[slice_gen]),
                .store_lane_mask_i(slice_store_lane_mask[slice_gen]),
                .store_word_addr_i(slice_store_word_addr[slice_gen])
            );
        end
    endgenerate

endmodule
