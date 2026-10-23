`timescale 1ns/1ps

/*
 * A0 MC-NOC-P1 topology-neutral logical request router.
 *
 * One post-cluster-endpoint load-line request stream enters per cluster. The
 * complete line address alone selects a deterministic home slice. Each slice
 * owns an independent round-robin arbiter and one-entry registered elastic
 * hold, so unrelated slices can progress independently and output payloads
 * remain stable under backpressure.
 *
 * The network tag remains {cluster_id, cu_id, local_tag}. The cluster and CU
 * identity fields are checked fail-closed at ingress; the local tag is opaque.
 * This block deliberately contains no response routing, L2, store path,
 * coherence state, outstanding table, or physical-NoC topology.
 */
module a0_mc_noc_logical_request_router #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer MSHR_COUNT = 2,
    parameter integer LINE_WORDS = 8,
    parameter integer SLICE_COUNT = 4,
    parameter integer SLICE_HASH_SHIFT = 8,

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
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT)
) (
    input logic clk,
    input logic rst_n,

    input logic [CLUSTER_COUNT-1:0]
        cluster_req_valid_i,

    output logic [CLUSTER_COUNT-1:0]
        cluster_req_ready_o,

    input logic [NETWORK_TAG_W-1:0]
        cluster_req_network_tag_i [0:CLUSTER_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        cluster_req_line_addr_i [0:CLUSTER_COUNT-1],

    output logic [CLUSTER_COUNT-1:0]
        cluster_req_tag_error_o,

    output logic [SLICE_COUNT-1:0]
        slice_req_valid_o,

    input logic [SLICE_COUNT-1:0]
        slice_req_ready_i,

    output logic [NETWORK_TAG_W-1:0]
        slice_req_network_tag_o [0:SLICE_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        slice_req_line_addr_o [0:SLICE_COUNT-1]
);

    logic [CLUSTER_ID_W-1:0]
        slice_rr_q [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_hold_valid_q;

    logic [NETWORK_TAG_W-1:0]
        slice_hold_network_tag_q [0:SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_hold_line_addr_q [0:SLICE_COUNT-1];

    logic [CLUSTER_ID_W-1:0]
        cluster_req_cluster_id [0:CLUSTER_COUNT-1];

    logic [CU_ID_W-1:0]
        cluster_req_cu_id [0:CLUSTER_COUNT-1];

    logic [CLUSTER_COUNT-1:0]
        cluster_req_identity_valid;

    logic [SLICE_ID_W-1:0]
        cluster_target_slice [0:CLUSTER_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_slot_available;

    logic [SLICE_COUNT-1:0]
        slice_grant_found;

    logic [CLUSTER_ID_W-1:0]
        slice_grant_cluster [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_request_accept;

    integer request_cluster_index;
    integer request_slice_index;
    integer scan_offset;
    integer scan_cluster;
    integer output_slice_index;
    integer sequential_slice;

    genvar assertion_cluster;
    genvar assertion_slice;


    function automatic logic cluster_id_valid(
        input logic [CLUSTER_ID_W-1:0] cluster_id
    );
        cluster_id_valid =
            integer'(cluster_id) < CLUSTER_COUNT;
    endfunction


    function automatic logic cu_id_valid(
        input logic [CU_ID_W-1:0] cu_id
    );
        cu_id_valid =
            integer'(cu_id) < CUS_PER_CLUSTER;
    endfunction


    function automatic logic [SLICE_ID_W-1:0] line_to_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (SLICE_COUNT <= 1) begin
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
        if (CLUSTER_COUNT < 1) begin
            $fatal(1, "MC_NOC_P1 CLUSTER_COUNT must be >= 1");
        end
        if (CUS_PER_CLUSTER < 1 || CUS_PER_CLUSTER > 4) begin
            $fatal(1, "MC_NOC_P1 CUS_PER_CLUSTER must be 1..4");
        end
        if (MSHR_COUNT < 1) begin
            $fatal(1, "MC_NOC_P1 MSHR_COUNT must be >= 1");
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "MC_NOC_P1 LINE_WORDS must be >= 1");
        end
        if (
            LINE_WORDS >= 1
            && (LINE_WORDS & (LINE_WORDS - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P1 LINE_WORDS must be a power of two");
        end
        if (SLICE_COUNT < 1) begin
            $fatal(1, "MC_NOC_P1 SLICE_COUNT must be >= 1");
        end
        if (
            SLICE_COUNT >= 1
            && (SLICE_COUNT & (SLICE_COUNT - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P1 SLICE_COUNT must be a power of two");
        end
        if (SLICE_HASH_SHIFT < 0) begin
            $fatal(1, "MC_NOC_P1 SLICE_HASH_SHIFT must be >= 0");
        end
        if (
            SLICE_COUNT > 1
            && SLICE_HASH_SHIFT >= LINE_ADDR_W
        ) begin
            $fatal(
                1,
                "MC_NOC_P1 SLICE_HASH_SHIFT must be below LINE_ADDR_W"
            );
        end
        if (
            WORD_SELECT_W
            != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS))
        ) begin
            $fatal(1, "MC_NOC_P1 WORD_SELECT_W inconsistent");
        end
        if (LINE_ADDR_W != 32 - WORD_SELECT_W || LINE_ADDR_W < 1) begin
            $fatal(1, "MC_NOC_P1 LINE_ADDR_W inconsistent");
        end
        if (
            CLUSTER_ID_W
            != ((CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P1 CLUSTER_ID_W inconsistent");
        end
        if (
            CU_ID_W
            != ((CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER))
        ) begin
            $fatal(1, "MC_NOC_P1 CU_ID_W inconsistent");
        end
        if (
            LOCAL_TAG_W
            != ((MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P1 LOCAL_TAG_W inconsistent");
        end
        if (CLUSTER_LOCAL_TAG_W != CU_ID_W + LOCAL_TAG_W) begin
            $fatal(1, "MC_NOC_P1 CLUSTER_LOCAL_TAG_W inconsistent");
        end
        if (
            NETWORK_TAG_W
            != CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
        ) begin
            $fatal(1, "MC_NOC_P1 NETWORK_TAG_W inconsistent");
        end
        if (
            SLICE_ID_W
            != ((SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P1 SLICE_ID_W inconsistent");
        end
    end


    always_comb begin
        cluster_req_ready_o = '0;
        cluster_req_tag_error_o = '0;
        slice_slot_available = '0;
        slice_grant_found = '0;
        slice_request_accept = '0;

        for (
            request_cluster_index = 0;
            request_cluster_index < CLUSTER_COUNT;
            request_cluster_index = request_cluster_index + 1
        ) begin
            cluster_req_cluster_id[request_cluster_index] =
                cluster_req_network_tag_i[request_cluster_index][
                    NETWORK_TAG_W-1 -: CLUSTER_ID_W
                ];

            cluster_req_cu_id[request_cluster_index] =
                cluster_req_network_tag_i[request_cluster_index][
                    CLUSTER_LOCAL_TAG_W-1 -: CU_ID_W
                ];

            cluster_req_identity_valid[request_cluster_index] =
                cluster_id_valid(
                    cluster_req_cluster_id[request_cluster_index]
                )
                && cluster_req_cluster_id[request_cluster_index]
                    == CLUSTER_ID_W'(request_cluster_index)
                && cu_id_valid(
                    cluster_req_cu_id[request_cluster_index]
                );

            cluster_target_slice[request_cluster_index] =
                line_to_slice(
                    cluster_req_line_addr_i[request_cluster_index]
                );

            cluster_req_tag_error_o[request_cluster_index] =
                rst_n
                && cluster_req_valid_i[request_cluster_index]
                && !cluster_req_identity_valid[request_cluster_index];
        end

        for (
            request_slice_index = 0;
            request_slice_index < SLICE_COUNT;
            request_slice_index = request_slice_index + 1
        ) begin
            slice_slot_available[request_slice_index] =
                rst_n
                && (
                    !slice_hold_valid_q[request_slice_index]
                    || slice_req_ready_i[request_slice_index]
                );

            slice_grant_cluster[request_slice_index] = '0;
            scan_cluster = 0;

            if (slice_slot_available[request_slice_index]) begin
                for (
                    scan_offset = 0;
                    scan_offset < CLUSTER_COUNT;
                    scan_offset = scan_offset + 1
                ) begin
                    scan_cluster =
                        integer'(slice_rr_q[request_slice_index])
                        + scan_offset;

                    if (scan_cluster >= CLUSTER_COUNT) begin
                        scan_cluster = scan_cluster - CLUSTER_COUNT;
                    end

                    if (
                        !slice_grant_found[request_slice_index]
                        && cluster_req_valid_i[scan_cluster]
                        && cluster_req_identity_valid[scan_cluster]
                        && integer'(cluster_target_slice[scan_cluster])
                            == request_slice_index
                    ) begin
                        slice_grant_found[request_slice_index] = 1'b1;
                        slice_grant_cluster[request_slice_index] =
                            CLUSTER_ID_W'(scan_cluster);
                    end
                end
            end

            if (slice_grant_found[request_slice_index]) begin
                cluster_req_ready_o[
                    integer'(slice_grant_cluster[request_slice_index])
                ] = 1'b1;
            end

            slice_request_accept[request_slice_index] =
                slice_grant_found[request_slice_index]
                && cluster_req_valid_i[
                    integer'(slice_grant_cluster[request_slice_index])
                ]
                && cluster_req_ready_o[
                    integer'(slice_grant_cluster[request_slice_index])
                ];
        end
    end


    always_comb begin
        for (
            output_slice_index = 0;
            output_slice_index < SLICE_COUNT;
            output_slice_index = output_slice_index + 1
        ) begin
            slice_req_valid_o[output_slice_index] =
                rst_n && slice_hold_valid_q[output_slice_index];

            slice_req_network_tag_o[output_slice_index] =
                slice_hold_network_tag_q[output_slice_index];

            slice_req_line_addr_o[output_slice_index] =
                slice_hold_line_addr_q[output_slice_index];
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                slice_rr_q[sequential_slice] <= '0;
                slice_hold_valid_q[sequential_slice] <= 1'b0;
                slice_hold_network_tag_q[sequential_slice] <= '0;
                slice_hold_line_addr_q[sequential_slice] <= '0;
            end
        end else begin
            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                /* Enqueue wins over dequeue for bubble-free turnover. */
                if (slice_request_accept[sequential_slice]) begin
                    slice_hold_valid_q[sequential_slice] <= 1'b1;
                    slice_hold_network_tag_q[sequential_slice] <=
                        cluster_req_network_tag_i[
                            integer'(slice_grant_cluster[sequential_slice])
                        ];
                    slice_hold_line_addr_q[sequential_slice] <=
                        cluster_req_line_addr_i[
                            integer'(slice_grant_cluster[sequential_slice])
                        ];

                    if (
                        integer'(slice_grant_cluster[sequential_slice])
                        == CLUSTER_COUNT - 1
                    ) begin
                        slice_rr_q[sequential_slice] <= '0;
                    end else begin
                        slice_rr_q[sequential_slice] <=
                            CLUSTER_ID_W'(
                                integer'(
                                    slice_grant_cluster[sequential_slice]
                                ) + 1
                            );
                    end
                end else if (
                    slice_hold_valid_q[sequential_slice]
                    && slice_req_ready_i[sequential_slice]
                ) begin
                    slice_hold_valid_q[sequential_slice] <= 1'b0;
                end
            end
        end
    end


    generate
        for (
            assertion_cluster = 0;
            assertion_cluster < CLUSTER_COUNT;
            assertion_cluster = assertion_cluster + 1
        ) begin : gen_cluster_request_assertions
            property invalid_identity_cannot_handshake;
                @(posedge clk)
                disable iff (!rst_n)
                cluster_req_valid_i[assertion_cluster]
                && !cluster_req_identity_valid[assertion_cluster]
                |-> !cluster_req_ready_o[assertion_cluster];
            endproperty

            assert property (invalid_identity_cannot_handshake)
                else $fatal(
                    1,
                    "MC_NOC_P1 invalid request identity handshook"
                );


            property tag_error_is_fail_closed;
                @(posedge clk)
                disable iff (!rst_n)
                cluster_req_tag_error_o[assertion_cluster]
                |-> cluster_req_valid_i[assertion_cluster]
                    && !cluster_req_ready_o[assertion_cluster];
            endproperty

            assert property (tag_error_is_fail_closed)
                else $fatal(
                    1,
                    "MC_NOC_P1 tag error did not fail closed"
                );
        end

        for (
            assertion_slice = 0;
            assertion_slice < SLICE_COUNT;
            assertion_slice = assertion_slice + 1
        ) begin : gen_slice_request_assertions
            property request_output_stable_under_stall;
                @(posedge clk)
                disable iff (!rst_n)
                slice_req_valid_o[assertion_slice]
                && !slice_req_ready_i[assertion_slice]
                |=> slice_req_valid_o[assertion_slice]
                    && $stable(
                        slice_req_network_tag_o[assertion_slice]
                    )
                    && $stable(
                        slice_req_line_addr_o[assertion_slice]
                    );
            endproperty

            assert property (request_output_stable_under_stall)
                else $fatal(
                    1,
                    "MC_NOC_P1 request payload changed under stall"
                );


            property request_output_matches_home_slice;
                @(posedge clk)
                disable iff (!rst_n)
                slice_req_valid_o[assertion_slice]
                |-> integer'(
                        line_to_slice(
                            slice_req_line_addr_o[assertion_slice]
                        )
                    ) == assertion_slice;
            endproperty

            assert property (request_output_matches_home_slice)
                else $fatal(
                    1,
                    "MC_NOC_P1 request emitted by wrong home slice"
                );


            property round_robin_cursor_is_legal;
                @(posedge clk)
                disable iff (!rst_n)
                integer'(slice_rr_q[assertion_slice]) < CLUSTER_COUNT;
            endproperty

            assert property (round_robin_cursor_is_legal)
                else $fatal(
                    1,
                    "MC_NOC_P1 round-robin cursor out of range"
                );
        end
    endgenerate


    property reset_clears_request_holds;
        @(posedge clk)
        !rst_n
        |=> slice_hold_valid_q == '0;
    endproperty

    assert property (reset_clears_request_holds)
        else $fatal(1, "MC_NOC_P1 reset did not clear request holds");

endmodule
