`timescale 1ns/1ps

/* PROD-SEAM-P4 stale-refill retry/squash successor. */
module a0_mc_noc_sliced_l2_store_order_subsystem #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer MSHR_COUNT = 2,
    parameter integer LINE_WORDS = 8,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer L2_SET_COUNT_PER_SLICE = 256,
    parameter integer L2_MISS_COUNT_PER_SLICE = 16,
    parameter integer STORE_LANES = CLUSTER_COUNT * CUS_PER_CLUSTER * 32,

    parameter integer SLICE_HASH_SHIFT =
        (L2_SET_COUNT_PER_SLICE <= 1)
            ? 0
            : $clog2(L2_SET_COUNT_PER_SLICE),

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W,

    parameter integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT),

    parameter integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER),

    parameter integer LOCAL_TAG_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),

    parameter integer CLUSTER_LOCAL_TAG_W =
        CU_ID_W + LOCAL_TAG_W,

    parameter integer NETWORK_TAG_W =
        CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W,

    parameter integer SLICE_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT),

    parameter integer CLUSTER_MAX_OUTSTANDING =
        CUS_PER_CLUSTER * MSHR_COUNT,

    parameter integer OWNER_SLOT_W =
        (CLUSTER_MAX_OUTSTANDING <= 1)
            ? 1
            : $clog2(CLUSTER_MAX_OUTSTANDING)
) (
    input logic clk,
    input logic rst_n,

    /* One post-cluster-fabric request stream per cluster. */
    input logic [CLUSTER_COUNT-1:0]
        cluster_local_req_valid_i,

    output logic [CLUSTER_COUNT-1:0]
        cluster_local_req_ready_o,

    input logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_local_req_tag_i [0:CLUSTER_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        cluster_local_req_line_addr_i [0:CLUSTER_COUNT-1],

    output logic [CLUSTER_COUNT-1:0]
        cluster_local_req_tag_error_o,

    /* Proper ready/valid response stream restored to each cluster. */
    output logic [CLUSTER_COUNT-1:0]
        cluster_local_resp_valid_o,

    input logic [CLUSTER_COUNT-1:0]
        cluster_local_resp_ready_i,

    output logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_local_resp_tag_o [0:CLUSTER_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        cluster_local_resp_line_addr_o [0:CLUSTER_COUNT-1],

    output logic
        cluster_local_resp_fault_o [0:CLUSTER_COUNT-1],

    output logic [31:0]
        cluster_local_resp_data_o
            [0:CLUSTER_COUNT-1]
            [0:LINE_WORDS-1],

    /* Internal-boundary diagnostics are kept distinct and fail-stop. */
    /* Conservative global physical-store observation broadcast to all slices. */
    input logic global_store_valid_i,

    input logic [STORE_LANES-1:0]
        global_store_lane_mask_i,

    input logic [31:0]
        global_store_word_addr_i [0:STORE_LANES-1],

    output logic [CLUSTER_COUNT-1:0]
        noc_req_tag_error_o,

    output logic [L2_SLICE_COUNT-1:0]
        slice_resp_protocol_error_o,

    output logic [CLUSTER_COUNT-1:0]
        noc_resp_tag_error_o,

    /* One independent ready/valid request port per L2 backend. */
    output logic [L2_SLICE_COUNT-1:0]
        line_mem_req_valid_o,

    input logic [L2_SLICE_COUNT-1:0]
        line_mem_req_ready_i,

    output logic [NETWORK_TAG_W-1:0]
        line_mem_req_network_tag_o [0:L2_SLICE_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1],

    /* Backend responses deliberately retain the existing no-ready contract. */
    input logic [L2_SLICE_COUNT-1:0]
        line_mem_resp_valid_i,

    input logic [NETWORK_TAG_W-1:0]
        line_mem_resp_network_tag_i [0:L2_SLICE_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1],

    input logic
        line_mem_resp_fault_i [0:L2_SLICE_COUNT-1],

    input logic [31:0]
        line_mem_resp_data_i
            [0:L2_SLICE_COUNT-1]
            [0:LINE_WORDS-1]
);

    localparam integer RETRY_SLOT_COUNT = (1 << CLUSTER_LOCAL_TAG_W);
    localparam integer TRACK_SLOT_W =
        (L2_MISS_COUNT_PER_SLICE <= 1) ? 1 : $clog2(L2_MISS_COUNT_PER_SLICE);

    logic [CLUSTER_COUNT-1:0] p3_req_valid;
    logic [CLUSTER_COUNT-1:0] p3_req_ready;
    logic [CLUSTER_LOCAL_TAG_W-1:0] p3_req_tag [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0] p3_req_addr [0:CLUSTER_COUNT-1];
    logic [CLUSTER_COUNT-1:0] p3_req_tag_error;

    logic [CLUSTER_COUNT-1:0] p3_resp_valid;
    logic [CLUSTER_COUNT-1:0] p3_resp_ready;
    logic [CLUSTER_LOCAL_TAG_W-1:0] p3_resp_tag [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0] p3_resp_addr [0:CLUSTER_COUNT-1];
    logic p3_resp_fault [0:CLUSTER_COUNT-1];
    logic [31:0] p3_resp_data [0:CLUSTER_COUNT-1][0:LINE_WORDS-1];

    logic retry_valid_q [0:CLUSTER_COUNT-1][0:RETRY_SLOT_COUNT-1];
    logic retry_wait_drop_q [0:CLUSTER_COUNT-1][0:RETRY_SLOT_COUNT-1];
    logic [LINE_ADDR_W-1:0] retry_addr_q [0:CLUSTER_COUNT-1][0:RETRY_SLOT_COUNT-1];
    logic retry_found [0:CLUSTER_COUNT-1];
    logic [CLUSTER_LOCAL_TAG_W-1:0] retry_tag [0:CLUSTER_COUNT-1];
    logic suppress_resp [0:CLUSTER_COUNT-1];

    logic track_valid_q [0:L2_SLICE_COUNT-1][0:L2_MISS_COUNT_PER_SLICE-1];
    logic [NETWORK_TAG_W-1:0] track_tag_q [0:L2_SLICE_COUNT-1][0:L2_MISS_COUNT_PER_SLICE-1];
    logic [LINE_ADDR_W-1:0] track_addr_q [0:L2_SLICE_COUNT-1][0:L2_MISS_COUNT_PER_SLICE-1];
    logic track_stale_q [0:L2_SLICE_COUNT-1][0:L2_MISS_COUNT_PER_SLICE-1];
    logic track_free_found [0:L2_SLICE_COUNT-1];
    logic [TRACK_SLOT_W-1:0] track_free_slot [0:L2_SLICE_COUNT-1];
    logic resp_track_found [0:L2_SLICE_COUNT-1];
    logic [TRACK_SLOT_W-1:0] resp_track_slot [0:L2_SLICE_COUNT-1];
    logic resp_stale [0:L2_SLICE_COUNT-1];
    logic req_fire [0:L2_SLICE_COUNT-1];
    logic resp_samecycle_req [0:L2_SLICE_COUNT-1];


    function automatic logic store_conflicts_line(input logic [LINE_ADDR_W-1:0] line_addr);
        integer sl;
        begin
            store_conflicts_line = 1'b0;
            if (global_store_valid_i) begin
                for (sl = 0; sl < STORE_LANES; sl = sl + 1) begin
                    if (global_store_lane_mask_i[sl]
                        && global_store_word_addr_i[sl][31:WORD_SELECT_W] == line_addr)
                        store_conflicts_line = 1'b1;
                end
            end
        end
    endfunction

    always_comb begin
        for (integer c = 0; c < CLUSTER_COUNT; c = c + 1) begin
            retry_found[c] = 1'b0;
            retry_tag[c] = '0;
            for (integer t = 0; t < RETRY_SLOT_COUNT; t = t + 1) begin
                if (!retry_found[c] && retry_valid_q[c][t] && !retry_wait_drop_q[c][t]) begin
                    retry_found[c] = 1'b1;
                    retry_tag[c] = CLUSTER_LOCAL_TAG_W'(t);
                end
            end
            p3_req_valid[c] = retry_found[c] ? 1'b1 : cluster_local_req_valid_i[c];
            p3_req_tag[c] = retry_found[c] ? retry_tag[c] : cluster_local_req_tag_i[c];
            p3_req_addr[c] = retry_found[c]
                ? retry_addr_q[c][integer'(retry_tag[c])]
                : cluster_local_req_line_addr_i[c];
        end
    end

    always_comb begin
        for (integer c = 0; c < CLUSTER_COUNT; c = c + 1) begin
            cluster_local_req_ready_o[c] = !retry_found[c] && p3_req_ready[c];
            suppress_resp[c] = p3_resp_valid[c]
                && retry_valid_q[c][integer'(p3_resp_tag[c])]
                && retry_wait_drop_q[c][integer'(p3_resp_tag[c])]
                && retry_addr_q[c][integer'(p3_resp_tag[c])] == p3_resp_addr[c];
            cluster_local_resp_valid_o[c] = p3_resp_valid[c] && !suppress_resp[c];
            cluster_local_resp_tag_o[c] = p3_resp_tag[c];
            cluster_local_resp_line_addr_o[c] = p3_resp_addr[c];
            cluster_local_resp_fault_o[c] = p3_resp_fault[c];
            p3_resp_ready[c] = suppress_resp[c] ? 1'b1 : cluster_local_resp_ready_i[c];
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                cluster_local_resp_data_o[c][word] = p3_resp_data[c][word];
            cluster_local_req_tag_error_o[c] = p3_req_tag_error[c] && !retry_found[c];
        end
    end

    always_comb begin
        for (integer s = 0; s < L2_SLICE_COUNT; s = s + 1) begin
            track_free_found[s] = 1'b0;
            track_free_slot[s] = '0;
            resp_track_found[s] = 1'b0;
            resp_track_slot[s] = '0;
            for (integer m = 0; m < L2_MISS_COUNT_PER_SLICE; m = m + 1) begin
                if (!track_free_found[s] && !track_valid_q[s][m]) begin
                    track_free_found[s] = 1'b1;
                    track_free_slot[s] = TRACK_SLOT_W'(m);
                end
                if (!resp_track_found[s] && track_valid_q[s][m]
                    && track_tag_q[s][m] == line_mem_resp_network_tag_i[s]
                    && track_addr_q[s][m] == line_mem_resp_line_addr_i[s]) begin
                    resp_track_found[s] = 1'b1;
                    resp_track_slot[s] = TRACK_SLOT_W'(m);
                end
            end
            req_fire[s] = line_mem_req_valid_o[s] && line_mem_req_ready_i[s];
            resp_samecycle_req[s] = line_mem_resp_valid_i[s] && req_fire[s]
                && line_mem_req_network_tag_o[s] == line_mem_resp_network_tag_i[s]
                && line_mem_req_line_addr_o[s] == line_mem_resp_line_addr_i[s];
            resp_stale[s] = line_mem_resp_valid_i[s] && (
                (resp_track_found[s]
                    && (track_stale_q[s][integer'(resp_track_slot[s])]
                        || store_conflicts_line(line_mem_resp_line_addr_i[s])))
                || (!resp_track_found[s] && resp_samecycle_req[s]
                    && store_conflicts_line(line_mem_resp_line_addr_i[s]))
            );
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (integer c = 0; c < CLUSTER_COUNT; c = c + 1)
                for (integer t = 0; t < RETRY_SLOT_COUNT; t = t + 1) begin
                    retry_valid_q[c][t] <= 1'b0;
                    retry_wait_drop_q[c][t] <= 1'b0;
                    retry_addr_q[c][t] <= '0;
                end
            for (integer s = 0; s < L2_SLICE_COUNT; s = s + 1)
                for (integer m = 0; m < L2_MISS_COUNT_PER_SLICE; m = m + 1) begin
                    track_valid_q[s][m] <= 1'b0;
                    track_tag_q[s][m] <= '0;
                    track_addr_q[s][m] <= '0;
                    track_stale_q[s][m] <= 1'b0;
                end
        end else begin
            for (integer c = 0; c < CLUSTER_COUNT; c = c + 1) begin
                if (suppress_resp[c] && p3_resp_ready[c]) begin
                    retry_wait_drop_q[c][integer'(p3_resp_tag[c])] <= 1'b0;
                end
                if (retry_found[c] && p3_req_valid[c] && p3_req_ready[c]) begin
                    retry_valid_q[c][integer'(retry_tag[c])] <= 1'b0;
                    retry_wait_drop_q[c][integer'(retry_tag[c])] <= 1'b0;
                end
            end

            for (integer s = 0; s < L2_SLICE_COUNT; s = s + 1) begin
                if (global_store_valid_i) begin
                    for (integer m = 0; m < L2_MISS_COUNT_PER_SLICE; m = m + 1)
                        if (track_valid_q[s][m] && store_conflicts_line(track_addr_q[s][m]))
                            track_stale_q[s][m] <= 1'b1;
                end

                if (req_fire[s]) begin
                    if (!track_free_found[s])
                        $fatal(1, "PROD_SEAM_P4_TRACKER_OVERFLOW");
                    track_valid_q[s][integer'(track_free_slot[s])] <= 1'b1;
                    track_tag_q[s][integer'(track_free_slot[s])] <= line_mem_req_network_tag_o[s];
                    track_addr_q[s][integer'(track_free_slot[s])] <= line_mem_req_line_addr_o[s];
                    track_stale_q[s][integer'(track_free_slot[s])] <= store_conflicts_line(line_mem_req_line_addr_o[s]);
                end

                if (line_mem_resp_valid_i[s] && resp_track_found[s]) begin
                    track_valid_q[s][integer'(resp_track_slot[s])] <= 1'b0;
                    track_stale_q[s][integer'(resp_track_slot[s])] <= 1'b0;
                end else if (line_mem_resp_valid_i[s] && resp_samecycle_req[s]) begin
                    track_valid_q[s][integer'(track_free_slot[s])] <= 1'b0;
                    track_stale_q[s][integer'(track_free_slot[s])] <= 1'b0;
                end

                if (resp_stale[s]) begin
                    if (integer'(line_mem_resp_network_tag_i[s][NETWORK_TAG_W-1 -: CLUSTER_ID_W]) >= CLUSTER_COUNT)
                        $fatal(1, "PROD_SEAM_P4_STALE_IDENTITY_RANGE");
                    if (retry_valid_q[
                        integer'(line_mem_resp_network_tag_i[s][NETWORK_TAG_W-1 -: CLUSTER_ID_W])
                    ][integer'(line_mem_resp_network_tag_i[s][CLUSTER_LOCAL_TAG_W-1:0])])
                        $fatal(1, "PROD_SEAM_P4_DUPLICATE_RETRY");
                    retry_valid_q[
                        integer'(line_mem_resp_network_tag_i[s][NETWORK_TAG_W-1 -: CLUSTER_ID_W])
                    ][integer'(line_mem_resp_network_tag_i[s][CLUSTER_LOCAL_TAG_W-1:0])] <= 1'b1;
                    retry_wait_drop_q[
                        integer'(line_mem_resp_network_tag_i[s][NETWORK_TAG_W-1 -: CLUSTER_ID_W])
                    ][integer'(line_mem_resp_network_tag_i[s][CLUSTER_LOCAL_TAG_W-1:0])] <= 1'b1;
                    retry_addr_q[
                        integer'(line_mem_resp_network_tag_i[s][NETWORK_TAG_W-1 -: CLUSTER_ID_W])
                    ][integer'(line_mem_resp_network_tag_i[s][CLUSTER_LOCAL_TAG_W-1:0])]
                        <= line_mem_resp_line_addr_i[s];
                end
            end
        end
    end

    a0_mc_noc_sliced_l2_store_invalidate_subsystem #(
        .CLUSTER_COUNT(CLUSTER_COUNT), .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT), .LINE_WORDS(LINE_WORDS),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .L2_SET_COUNT_PER_SLICE(L2_SET_COUNT_PER_SLICE),
        .L2_MISS_COUNT_PER_SLICE(L2_MISS_COUNT_PER_SLICE),
        .STORE_LANES(STORE_LANES),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT), .SLICE_ID_W(SLICE_ID_W),
        .OWNER_SLOT_W(OWNER_SLOT_W)
    ) p3 (
        .clk(clk), .rst_n(rst_n),
        .cluster_local_req_valid_i(p3_req_valid),
        .cluster_local_req_ready_o(p3_req_ready),
        .cluster_local_req_tag_i(p3_req_tag),
        .cluster_local_req_line_addr_i(p3_req_addr),
        .cluster_local_req_tag_error_o(p3_req_tag_error),
        .cluster_local_resp_valid_o(p3_resp_valid),
        .cluster_local_resp_ready_i(p3_resp_ready),
        .cluster_local_resp_tag_o(p3_resp_tag),
        .cluster_local_resp_line_addr_o(p3_resp_addr),
        .cluster_local_resp_fault_o(p3_resp_fault),
        .cluster_local_resp_data_o(p3_resp_data),
        .global_store_valid_i(global_store_valid_i),
        .global_store_lane_mask_i(global_store_lane_mask_i),
        .global_store_word_addr_i(global_store_word_addr_i),
        .noc_req_tag_error_o(noc_req_tag_error_o),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .noc_resp_tag_error_o(noc_resp_tag_error_o),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_network_tag_o(line_mem_req_network_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_network_tag_i(line_mem_resp_network_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i)
    );

endmodule
