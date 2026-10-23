`timescale 1ns/1ps

/*
 * A0 PROD-SEAM-P3 store-aware multi-cluster sliced-L2 successor.
 *
 * One unchanged MC-NOC-P0 endpoint is instantiated per cluster.  Their
 * network-tagged request streams enter one unchanged MC-NOC-P2 transaction
 * router, whose per-slice requests cross the bounded registered seam below
 * before entering independent unchanged a0_l2_line_cache instances.  Each L2
 * slice exposes an independent line-memory backend.
 *
 * The only new runtime state is one registered elastic request hold per slice.
 * That no-bypass seam breaks the P2-ready/L2-valid combinational dependency
 * while preserving one transfer per cycle after its initial latency.  P3 adds
 * no response adaptation, store path, coherence state, or physical-NoC policy.
 * It preserves the closed load routing while broadcasting one conservative
 * global physical-store observation vector into every L2 slice.  This adds
 * invalidation/refill-kill visibility only; it does not add write allocation,
 * dirty state, writeback, atomics, or a coherent store-data transport.
 */
module a0_mc_noc_sliced_l2_store_invalidate_subsystem #(
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

    /* P0 endpoint request streams entering P2. */
    logic [CLUSTER_COUNT-1:0]
        endpoint_noc_req_valid;

    logic [CLUSTER_COUNT-1:0]
        endpoint_noc_req_ready;

    logic [NETWORK_TAG_W-1:0]
        endpoint_noc_req_network_tag [0:CLUSTER_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        endpoint_noc_req_line_addr [0:CLUSTER_COUNT-1];

    /* P2 response streams entering the corresponding P0 endpoints. */
    logic [CLUSTER_COUNT-1:0]
        router_cluster_resp_valid;

    logic [CLUSTER_COUNT-1:0]
        endpoint_noc_resp_ready;

    logic [NETWORK_TAG_W-1:0]
        router_cluster_resp_network_tag [0:CLUSTER_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        router_cluster_resp_line_addr [0:CLUSTER_COUNT-1];

    logic
        router_cluster_resp_fault [0:CLUSTER_COUNT-1];

    logic [31:0]
        router_cluster_resp_data
            [0:CLUSTER_COUNT-1]
            [0:LINE_WORDS-1];

    /* P2 request streams entering their physical home L2 slices. */
    logic [L2_SLICE_COUNT-1:0]
        router_slice_req_valid;

    logic [L2_SLICE_COUNT-1:0]
        router_slice_req_ready;

    logic [NETWORK_TAG_W-1:0]
        router_slice_req_network_tag [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        router_slice_req_line_addr [0:L2_SLICE_COUNT-1];

    /* Registered elastic request seam between P2 and each L2. */
    logic [L2_SLICE_COUNT-1:0]
        slice_req_hold_valid_q;

    logic [NETWORK_TAG_W-1:0]
        slice_req_hold_network_tag_q [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_req_hold_line_addr_q [0:L2_SLICE_COUNT-1];

    logic [L2_SLICE_COUNT-1:0]
        slice_req_enqueue;

    logic [L2_SLICE_COUNT-1:0]
        slice_req_dequeue;

    logic [L2_SLICE_COUNT-1:0]
        l2_slice_req_valid;

    logic [L2_SLICE_COUNT-1:0]
        l2_slice_req_ready;

    logic [NETWORK_TAG_W-1:0]
        l2_slice_req_network_tag [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        l2_slice_req_line_addr [0:L2_SLICE_COUNT-1];

    /* No-ready L2 responses entering P2 independently and concurrently. */
    logic [L2_SLICE_COUNT-1:0]
        l2_slice_resp_valid;

    logic [NETWORK_TAG_W-1:0]
        l2_slice_resp_network_tag [0:L2_SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        l2_slice_resp_line_addr [0:L2_SLICE_COUNT-1];

    logic
        l2_slice_resp_fault [0:L2_SLICE_COUNT-1];

    logic [31:0]
        l2_slice_resp_data
            [0:L2_SLICE_COUNT-1]
            [0:LINE_WORDS-1];

    initial begin
        if (CLUSTER_COUNT < 1) begin
            $fatal(1, "MC_NOC_P3 CLUSTER_COUNT must be >= 1");
        end
        if (CUS_PER_CLUSTER < 1 || CUS_PER_CLUSTER > 4) begin
            $fatal(1, "MC_NOC_P3 CUS_PER_CLUSTER must be 1..4");
        end
        if (MSHR_COUNT < 1) begin
            $fatal(1, "MC_NOC_P3 MSHR_COUNT must be >= 1");
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "MC_NOC_P3 LINE_WORDS must be >= 1");
        end
        if (
            LINE_WORDS >= 1
            && (LINE_WORDS & (LINE_WORDS - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P3 LINE_WORDS must be a power of two");
        end
        if (L2_SLICE_COUNT < 1) begin
            $fatal(1, "MC_NOC_P3 L2_SLICE_COUNT must be >= 1");
        end
        if (
            L2_SLICE_COUNT >= 1
            && (L2_SLICE_COUNT & (L2_SLICE_COUNT - 1)) != 0
        ) begin
            $fatal(
                1,
                "MC_NOC_P3 L2_SLICE_COUNT must be a power of two"
            );
        end
        if (L2_SET_COUNT_PER_SLICE < 1) begin
            $fatal(
                1,
                "MC_NOC_P3 L2_SET_COUNT_PER_SLICE must be >= 1"
            );
        end
        if (
            L2_SET_COUNT_PER_SLICE >= 1
            && (
                L2_SET_COUNT_PER_SLICE
                & (L2_SET_COUNT_PER_SLICE - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "MC_NOC_P3 L2_SET_COUNT_PER_SLICE must be a power of two"
            );
        end
        if (L2_MISS_COUNT_PER_SLICE < 1) begin
            $fatal(
                1,
                "MC_NOC_P3 L2_MISS_COUNT_PER_SLICE must be >= 1"
            );
        end
        if (STORE_LANES < 1) begin
            $fatal(1, "PROD_SEAM_P3 STORE_LANES must be >= 1");
        end
        if (SLICE_HASH_SHIFT < 0) begin
            $fatal(1, "MC_NOC_P3 SLICE_HASH_SHIFT must be >= 0");
        end
        if (
            L2_SLICE_COUNT > 1
            && SLICE_HASH_SHIFT >= LINE_ADDR_W
        ) begin
            $fatal(
                1,
                "MC_NOC_P3 SLICE_HASH_SHIFT must be below LINE_ADDR_W"
            );
        end
        if (
            L2_SET_COUNT_PER_SLICE > 1
            && $clog2(L2_SET_COUNT_PER_SLICE) >= LINE_ADDR_W
        ) begin
            $fatal(
                1,
                "MC_NOC_P3 L2_SET_COUNT_PER_SLICE must leave a tag bit"
            );
        end
        if (
            WORD_SELECT_W
            != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS))
        ) begin
            $fatal(1, "MC_NOC_P3 WORD_SELECT_W inconsistent");
        end
        if (LINE_ADDR_W != 32 - WORD_SELECT_W || LINE_ADDR_W < 1) begin
            $fatal(1, "MC_NOC_P3 LINE_ADDR_W inconsistent");
        end
        if (
            CLUSTER_ID_W
            != ((CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P3 CLUSTER_ID_W inconsistent");
        end
        if (
            CU_ID_W
            != ((CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER))
        ) begin
            $fatal(1, "MC_NOC_P3 CU_ID_W inconsistent");
        end
        if (
            LOCAL_TAG_W
            != ((MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P3 LOCAL_TAG_W inconsistent");
        end
        if (CLUSTER_LOCAL_TAG_W != CU_ID_W + LOCAL_TAG_W) begin
            $fatal(1, "MC_NOC_P3 CLUSTER_LOCAL_TAG_W inconsistent");
        end
        if (
            NETWORK_TAG_W
            != CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
        ) begin
            $fatal(1, "MC_NOC_P3 NETWORK_TAG_W inconsistent");
        end
        if (
            SLICE_ID_W
            != (
                (L2_SLICE_COUNT <= 1)
                    ? 1
                    : $clog2(L2_SLICE_COUNT)
            )
        ) begin
            $fatal(1, "MC_NOC_P3 SLICE_ID_W inconsistent");
        end
        if (
            CLUSTER_MAX_OUTSTANDING
            != CUS_PER_CLUSTER * MSHR_COUNT
            || CLUSTER_MAX_OUTSTANDING < 1
        ) begin
            $fatal(
                1,
                "MC_NOC_P3 CLUSTER_MAX_OUTSTANDING inconsistent"
            );
        end
        if (
            OWNER_SLOT_W
            != (
                (CLUSTER_MAX_OUTSTANDING <= 1)
                    ? 1
                    : $clog2(CLUSTER_MAX_OUTSTANDING)
            )
        ) begin
            $fatal(1, "MC_NOC_P3 OWNER_SLOT_W inconsistent");
        end
    end


    generate
        genvar cluster_gen;
        for (
            cluster_gen = 0;
            cluster_gen < CLUSTER_COUNT;
            cluster_gen = cluster_gen + 1
        ) begin : g_cluster_endpoint
            a0_cluster_line_noc_endpoint #(
                .CLUSTER_COUNT(CLUSTER_COUNT),
                .CLUSTER_ID(cluster_gen),
                .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
                .MSHR_COUNT(MSHR_COUNT),
                .LINE_WORDS(LINE_WORDS),
                .WORD_SELECT_W(WORD_SELECT_W),
                .LINE_ADDR_W(LINE_ADDR_W),
                .CLUSTER_ID_W(CLUSTER_ID_W),
                .CU_ID_W(CU_ID_W),
                .LOCAL_TAG_W(LOCAL_TAG_W),
                .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
                .NETWORK_TAG_W(NETWORK_TAG_W)
            ) u_endpoint (
                .clk(clk),
                .rst_n(rst_n),
                .local_req_valid_i(
                    cluster_local_req_valid_i[cluster_gen]
                ),
                .local_req_ready_o(
                    cluster_local_req_ready_o[cluster_gen]
                ),
                .local_req_tag_i(cluster_local_req_tag_i[cluster_gen]),
                .local_req_line_addr_i(
                    cluster_local_req_line_addr_i[cluster_gen]
                ),
                .local_req_tag_error_o(
                    cluster_local_req_tag_error_o[cluster_gen]
                ),
                .noc_req_valid_o(endpoint_noc_req_valid[cluster_gen]),
                .noc_req_ready_i(endpoint_noc_req_ready[cluster_gen]),
                .noc_req_network_tag_o(
                    endpoint_noc_req_network_tag[cluster_gen]
                ),
                .noc_req_line_addr_o(
                    endpoint_noc_req_line_addr[cluster_gen]
                ),
                .noc_resp_valid_i(router_cluster_resp_valid[cluster_gen]),
                .noc_resp_ready_o(endpoint_noc_resp_ready[cluster_gen]),
                .noc_resp_network_tag_i(
                    router_cluster_resp_network_tag[cluster_gen]
                ),
                .noc_resp_line_addr_i(
                    router_cluster_resp_line_addr[cluster_gen]
                ),
                .noc_resp_fault_i(router_cluster_resp_fault[cluster_gen]),
                .noc_resp_data_i(router_cluster_resp_data[cluster_gen]),
                .noc_resp_tag_error_o(noc_resp_tag_error_o[cluster_gen]),
                .local_resp_valid_o(
                    cluster_local_resp_valid_o[cluster_gen]
                ),
                .local_resp_ready_i(
                    cluster_local_resp_ready_i[cluster_gen]
                ),
                .local_resp_tag_o(cluster_local_resp_tag_o[cluster_gen]),
                .local_resp_line_addr_o(
                    cluster_local_resp_line_addr_o[cluster_gen]
                ),
                .local_resp_fault_o(
                    cluster_local_resp_fault_o[cluster_gen]
                ),
                .local_resp_data_o(cluster_local_resp_data_o[cluster_gen])
            );
        end
    endgenerate


    a0_mc_noc_logical_transaction_router #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(L2_SLICE_COUNT),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .CLUSTER_ID_W(CLUSTER_ID_W),
        .CU_ID_W(CU_ID_W),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .SLICE_ID_W(SLICE_ID_W),
        .CLUSTER_MAX_OUTSTANDING(CLUSTER_MAX_OUTSTANDING),
        .OWNER_SLOT_W(OWNER_SLOT_W)
    ) u_transaction_router (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_req_valid_i(endpoint_noc_req_valid),
        .cluster_req_ready_o(endpoint_noc_req_ready),
        .cluster_req_network_tag_i(endpoint_noc_req_network_tag),
        .cluster_req_line_addr_i(endpoint_noc_req_line_addr),
        .cluster_req_tag_error_o(noc_req_tag_error_o),
        .slice_req_valid_o(router_slice_req_valid),
        .slice_req_ready_i(router_slice_req_ready),
        .slice_req_network_tag_o(router_slice_req_network_tag),
        .slice_req_line_addr_o(router_slice_req_line_addr),
        .slice_resp_valid_i(l2_slice_resp_valid),
        .slice_resp_network_tag_i(l2_slice_resp_network_tag),
        .slice_resp_line_addr_i(l2_slice_resp_line_addr),
        .slice_resp_fault_i(l2_slice_resp_fault),
        .slice_resp_data_i(l2_slice_resp_data),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .cluster_resp_valid_o(router_cluster_resp_valid),
        .cluster_resp_ready_i(endpoint_noc_resp_ready),
        .cluster_resp_network_tag_o(router_cluster_resp_network_tag),
        .cluster_resp_line_addr_o(router_cluster_resp_line_addr),
        .cluster_resp_fault_o(router_cluster_resp_fault),
        .cluster_resp_data_o(router_cluster_resp_data)
    );


    generate
        genvar slice_gen;
        for (
            slice_gen = 0;
            slice_gen < L2_SLICE_COUNT;
            slice_gen = slice_gen + 1
        ) begin : g_l2_slice
            assign router_slice_req_ready[slice_gen] =
                rst_n
                && (
                    !slice_req_hold_valid_q[slice_gen]
                    || l2_slice_req_ready[slice_gen]
                );

            assign slice_req_enqueue[slice_gen] =
                router_slice_req_valid[slice_gen]
                && router_slice_req_ready[slice_gen];

            assign l2_slice_req_valid[slice_gen] =
                rst_n
                && slice_req_hold_valid_q[slice_gen];

            assign l2_slice_req_network_tag[slice_gen] =
                slice_req_hold_network_tag_q[slice_gen];

            assign l2_slice_req_line_addr[slice_gen] =
                slice_req_hold_line_addr_q[slice_gen];

            assign slice_req_dequeue[slice_gen] =
                l2_slice_req_valid[slice_gen]
                && l2_slice_req_ready[slice_gen];

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    slice_req_hold_valid_q[slice_gen] <= 1'b0;
                    slice_req_hold_network_tag_q[slice_gen] <= '0;
                    slice_req_hold_line_addr_q[slice_gen] <= '0;
                end else begin
                    /* Enqueue wins over dequeue for bubble-free turnover. */
                    if (slice_req_enqueue[slice_gen]) begin
                        slice_req_hold_valid_q[slice_gen] <= 1'b1;
                        slice_req_hold_network_tag_q[slice_gen] <=
                            router_slice_req_network_tag[slice_gen];
                        slice_req_hold_line_addr_q[slice_gen] <=
                            router_slice_req_line_addr[slice_gen];
                    end else if (slice_req_dequeue[slice_gen]) begin
                        slice_req_hold_valid_q[slice_gen] <= 1'b0;
                    end
                end
            end

            property l2_request_output_stable_under_stall;
                @(posedge clk)
                disable iff (!rst_n)
                l2_slice_req_valid[slice_gen]
                && !l2_slice_req_ready[slice_gen]
                |=> l2_slice_req_valid[slice_gen]
                    && $stable(l2_slice_req_network_tag[slice_gen])
                    && $stable(l2_slice_req_line_addr[slice_gen]);
            endproperty

            assert property (l2_request_output_stable_under_stall)
                else $fatal(
                    1,
                    "MC_NOC_P3 L2 request payload changed under stall"
                );

            property reset_clears_slice_request_hold;
                @(posedge clk)
                !rst_n
                |=> !slice_req_hold_valid_q[slice_gen];
            endproperty

            assert property (reset_clears_slice_request_hold)
                else $fatal(
                    1,
                    "MC_NOC_P3 reset did not clear slice request hold"
                );

            a0_l2_line_cache #(
                .STORE_LANES(STORE_LANES),
                .LINE_WORDS(LINE_WORDS),
                .SET_COUNT(L2_SET_COUNT_PER_SLICE),
                .GLOBAL_TAG_W(NETWORK_TAG_W),
                .MISS_COUNT(L2_MISS_COUNT_PER_SLICE),
                .WORD_SELECT_W(WORD_SELECT_W),
                .LINE_ADDR_W(LINE_ADDR_W)
            ) u_l2 (
                .clk(clk),
                .rst_n(rst_n),
                .line_req_valid_i(l2_slice_req_valid[slice_gen]),
                .line_req_ready_o(l2_slice_req_ready[slice_gen]),
                .line_req_global_tag_i(
                    l2_slice_req_network_tag[slice_gen]
                ),
                .line_req_line_addr_i(
                    l2_slice_req_line_addr[slice_gen]
                ),
                .line_mem_req_valid_o(line_mem_req_valid_o[slice_gen]),
                .line_mem_req_ready_i(line_mem_req_ready_i[slice_gen]),
                .line_mem_req_global_tag_o(
                    line_mem_req_network_tag_o[slice_gen]
                ),
                .line_mem_req_line_addr_o(
                    line_mem_req_line_addr_o[slice_gen]
                ),
                .line_mem_resp_valid_i(line_mem_resp_valid_i[slice_gen]),
                .line_mem_resp_global_tag_i(
                    line_mem_resp_network_tag_i[slice_gen]
                ),
                .line_mem_resp_line_addr_i(
                    line_mem_resp_line_addr_i[slice_gen]
                ),
                .line_mem_resp_fault_i(line_mem_resp_fault_i[slice_gen]),
                .line_mem_resp_data_i(line_mem_resp_data_i[slice_gen]),
                .line_resp_valid_o(l2_slice_resp_valid[slice_gen]),
                .line_resp_global_tag_o(
                    l2_slice_resp_network_tag[slice_gen]
                ),
                .line_resp_line_addr_o(
                    l2_slice_resp_line_addr[slice_gen]
                ),
                .line_resp_fault_o(l2_slice_resp_fault[slice_gen]),
                .line_resp_data_o(l2_slice_resp_data[slice_gen]),
                .store_valid_i(global_store_valid_i),
                .store_lane_mask_i(global_store_lane_mask_i),
                .store_word_addr_i(global_store_word_addr_i)
            );
        end
    endgenerate

endmodule
