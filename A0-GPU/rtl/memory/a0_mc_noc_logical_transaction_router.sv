`timescale 1ns/1ps

/*
 * A0 MC-NOC-P2 topology-neutral logical transaction router.
 *
 * The closed MC-NOC-P1 request router is instantiated unchanged.  Ownership
 * is reserved when a cluster request enters P1, follows the held P1 request
 * until its slice handshake, captures each no-ready slice response directly
 * into that reserved owner, and retires only when the destination cluster
 * accepts the response.
 *
 * The complete network tag {cluster_id, cu_id, local_tag} stays opaque.  Local
 * tag encodings are transport identity, not an MSHR-range check.  This block
 * contains no L2 storage, stores, coherence, or physical-NoC policy.
 */
module a0_mc_noc_logical_transaction_router #(
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
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),

    parameter integer CLUSTER_MAX_OUTSTANDING =
        CUS_PER_CLUSTER * MSHR_COUNT,

    parameter integer OWNER_SLOT_W =
        (CLUSTER_MAX_OUTSTANDING <= 1)
            ? 1
            : $clog2(CLUSTER_MAX_OUTSTANDING)
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
        slice_req_line_addr_o [0:SLICE_COUNT-1],

    /*
     * Slice responses deliberately have no ready.  Every protocol-correct
     * response writes its already-reserved owner slot on the presentation
     * edge, so independent simultaneous responses cannot overflow.
     */
    input logic [SLICE_COUNT-1:0]
        slice_resp_valid_i,

    input logic [NETWORK_TAG_W-1:0]
        slice_resp_network_tag_i [0:SLICE_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        slice_resp_line_addr_i [0:SLICE_COUNT-1],

    input logic
        slice_resp_fault_i [0:SLICE_COUNT-1],

    input logic [31:0]
        slice_resp_data_i
            [0:SLICE_COUNT-1]
            [0:LINE_WORDS-1],

    output logic [SLICE_COUNT-1:0]
        slice_resp_protocol_error_o,

    output logic [CLUSTER_COUNT-1:0]
        cluster_resp_valid_o,

    input logic [CLUSTER_COUNT-1:0]
        cluster_resp_ready_i,

    output logic [NETWORK_TAG_W-1:0]
        cluster_resp_network_tag_o [0:CLUSTER_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        cluster_resp_line_addr_o [0:CLUSTER_COUNT-1],

    output logic
        cluster_resp_fault_o [0:CLUSTER_COUNT-1],

    output logic [31:0]
        cluster_resp_data_o
            [0:CLUSTER_COUNT-1]
            [0:LINE_WORDS-1]
);

    localparam integer OWNER_STORAGE_SLOTS =
        (CLUSTER_MAX_OUTSTANDING < 1)
            ? 1
            : CLUSTER_MAX_OUTSTANDING;

    localparam logic [2:0] OWNER_FREE = 3'd0;
    localparam logic [2:0] OWNER_QUEUED = 3'd1;
    localparam logic [2:0] OWNER_AWAITING = 3'd2;
    localparam logic [2:0] OWNER_COMPLETE = 3'd3;
    localparam logic [2:0] OWNER_EMITTING = 3'd4;

    logic [CLUSTER_COUNT-1:0]
        p1_cluster_req_valid;

    logic [CLUSTER_COUNT-1:0]
        p1_cluster_req_ready;

    logic [CLUSTER_COUNT-1:0]
        p1_cluster_req_tag_error;

    logic [SLICE_COUNT-1:0]
        p1_slice_req_valid;

    logic [SLICE_COUNT-1:0]
        p1_slice_req_ready;

    logic [NETWORK_TAG_W-1:0]
        p1_slice_req_network_tag [0:SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        p1_slice_req_line_addr [0:SLICE_COUNT-1];

    logic [2:0] owner_state_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1];

    logic [NETWORK_TAG_W-1:0] owner_network_tag_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1];

    logic [LINE_ADDR_W-1:0] owner_expected_line_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1];

    logic [SLICE_ID_W-1:0] owner_expected_home_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1];

    logic owner_fault_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1];

    logic [31:0] owner_data_q
        [0:CLUSTER_COUNT-1]
        [0:OWNER_STORAGE_SLOTS-1]
        [0:LINE_WORDS-1];

    logic [CLUSTER_COUNT-1:0]
        cluster_emit_hold_valid_q;

    logic [OWNER_SLOT_W-1:0]
        cluster_emit_hold_slot_q [0:CLUSTER_COUNT-1];

    logic [OWNER_SLOT_W-1:0]
        cluster_service_rr_q [0:CLUSTER_COUNT-1];

    logic [CLUSTER_ID_W-1:0]
        ingress_cluster_id [0:CLUSTER_COUNT-1];

    logic [CU_ID_W-1:0]
        ingress_cu_id [0:CLUSTER_COUNT-1];

    logic [CLUSTER_COUNT-1:0]
        ingress_identity_valid;

    logic [CLUSTER_COUNT-1:0]
        ingress_owner_found;

    logic [CLUSTER_COUNT-1:0]
        ingress_free_found;

    logic [OWNER_SLOT_W-1:0]
        ingress_free_slot [0:CLUSTER_COUNT-1];

    logic [CLUSTER_COUNT-1:0]
        ingress_admissible;

    logic [CLUSTER_COUNT-1:0]
        ingress_accept;

    logic [SLICE_COUNT-1:0]
        slice_issue_owner_found;

    logic [OWNER_SLOT_W-1:0]
        slice_issue_owner_slot [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_issue_protocol_valid;

    logic [SLICE_COUNT-1:0]
        slice_issue_accept;

    logic [CLUSTER_ID_W-1:0]
        slice_issue_cluster_id [0:SLICE_COUNT-1];

    logic [CLUSTER_ID_W-1:0]
        response_cluster_id [0:SLICE_COUNT-1];

    logic [CU_ID_W-1:0]
        response_cu_id [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        response_identity_valid;

    logic [SLICE_COUNT-1:0]
        response_owner_found;

    logic [OWNER_SLOT_W-1:0]
        response_owner_slot [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        response_same_cycle_issue;

    logic [SLICE_COUNT-1:0]
        response_capture;

    logic [CLUSTER_COUNT-1:0]
        cluster_response_dequeue;

    logic [CLUSTER_COUNT-1:0]
        cluster_select_found;

    logic [OWNER_SLOT_W-1:0]
        cluster_select_slot [0:CLUSTER_COUNT-1];

    integer ingress_cluster;
    integer ingress_output_cluster;
    integer ingress_slot;
    integer issue_slice;
    integer issue_slot;
    integer response_slice;
    integer response_slot;
    integer response_issue_slice;
    integer output_cluster;
    integer output_word;
    integer select_cluster;
    integer select_offset;
    integer select_index;
    integer select_start;
    integer reset_cluster;
    integer reset_slot;
    integer reset_word;
    integer sequential_cluster;
    integer sequential_slice;
    integer sequential_word;

    genvar assertion_cluster;
    genvar assertion_slice;
    genvar assertion_word;


    function automatic logic cluster_id_valid(
        input logic [CLUSTER_ID_W-1:0] cluster_id
    );
        cluster_id_valid = integer'(cluster_id) < CLUSTER_COUNT;
    endfunction


    function automatic logic cu_id_valid(
        input logic [CU_ID_W-1:0] cu_id
    );
        cu_id_valid = integer'(cu_id) < CUS_PER_CLUSTER;
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
            $fatal(1, "MC_NOC_P2 CLUSTER_COUNT must be >= 1");
        end
        if (CUS_PER_CLUSTER < 1 || CUS_PER_CLUSTER > 4) begin
            $fatal(1, "MC_NOC_P2 CUS_PER_CLUSTER must be 1..4");
        end
        if (MSHR_COUNT < 1) begin
            $fatal(1, "MC_NOC_P2 MSHR_COUNT must be >= 1");
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "MC_NOC_P2 LINE_WORDS must be >= 1");
        end
        if (
            LINE_WORDS >= 1
            && (LINE_WORDS & (LINE_WORDS - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P2 LINE_WORDS must be a power of two");
        end
        if (SLICE_COUNT < 1) begin
            $fatal(1, "MC_NOC_P2 SLICE_COUNT must be >= 1");
        end
        if (
            SLICE_COUNT >= 1
            && (SLICE_COUNT & (SLICE_COUNT - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P2 SLICE_COUNT must be a power of two");
        end
        if (SLICE_HASH_SHIFT < 0) begin
            $fatal(1, "MC_NOC_P2 SLICE_HASH_SHIFT must be >= 0");
        end
        if (
            SLICE_COUNT > 1
            && SLICE_HASH_SHIFT >= LINE_ADDR_W
        ) begin
            $fatal(
                1,
                "MC_NOC_P2 SLICE_HASH_SHIFT must be below LINE_ADDR_W"
            );
        end
        if (
            WORD_SELECT_W
            != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS))
        ) begin
            $fatal(1, "MC_NOC_P2 WORD_SELECT_W inconsistent");
        end
        if (LINE_ADDR_W != 32 - WORD_SELECT_W || LINE_ADDR_W < 1) begin
            $fatal(1, "MC_NOC_P2 LINE_ADDR_W inconsistent");
        end
        if (
            CLUSTER_ID_W
            != ((CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P2 CLUSTER_ID_W inconsistent");
        end
        if (
            CU_ID_W
            != ((CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER))
        ) begin
            $fatal(1, "MC_NOC_P2 CU_ID_W inconsistent");
        end
        if (
            LOCAL_TAG_W
            != ((MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P2 LOCAL_TAG_W inconsistent");
        end
        if (CLUSTER_LOCAL_TAG_W != CU_ID_W + LOCAL_TAG_W) begin
            $fatal(1, "MC_NOC_P2 CLUSTER_LOCAL_TAG_W inconsistent");
        end
        if (
            NETWORK_TAG_W
            != CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
        ) begin
            $fatal(1, "MC_NOC_P2 NETWORK_TAG_W inconsistent");
        end
        if (
            SLICE_ID_W
            != ((SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P2 SLICE_ID_W inconsistent");
        end
        if (
            CLUSTER_MAX_OUTSTANDING
            != CUS_PER_CLUSTER * MSHR_COUNT
            || CLUSTER_MAX_OUTSTANDING < 1
        ) begin
            $fatal(
                1,
                "MC_NOC_P2 CLUSTER_MAX_OUTSTANDING inconsistent"
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
            $fatal(1, "MC_NOC_P2 OWNER_SLOT_W inconsistent");
        end
    end


    a0_mc_noc_logical_request_router #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(SLICE_COUNT),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .CLUSTER_ID_W(CLUSTER_ID_W),
        .CU_ID_W(CU_ID_W),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .SLICE_ID_W(SLICE_ID_W)
    ) u_request_router (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_req_valid_i(p1_cluster_req_valid),
        .cluster_req_ready_o(p1_cluster_req_ready),
        .cluster_req_network_tag_i(cluster_req_network_tag_i),
        .cluster_req_line_addr_i(cluster_req_line_addr_i),
        .cluster_req_tag_error_o(p1_cluster_req_tag_error),
        .slice_req_valid_o(p1_slice_req_valid),
        .slice_req_ready_i(p1_slice_req_ready),
        .slice_req_network_tag_o(p1_slice_req_network_tag),
        .slice_req_line_addr_o(p1_slice_req_line_addr)
    );


    always_comb begin
        for (
            output_cluster = 0;
            output_cluster < CLUSTER_COUNT;
            output_cluster = output_cluster + 1
        ) begin
            cluster_resp_valid_o[output_cluster] =
                rst_n
                && cluster_emit_hold_valid_q[output_cluster];

            cluster_resp_network_tag_o[output_cluster] =
                owner_network_tag_q[output_cluster][
                    integer'(cluster_emit_hold_slot_q[output_cluster])
                ];

            cluster_resp_line_addr_o[output_cluster] =
                owner_expected_line_q[output_cluster][
                    integer'(cluster_emit_hold_slot_q[output_cluster])
                ];

            cluster_resp_fault_o[output_cluster] =
                owner_fault_q[output_cluster][
                    integer'(cluster_emit_hold_slot_q[output_cluster])
                ];

            for (
                output_word = 0;
                output_word < LINE_WORDS;
                output_word = output_word + 1
            ) begin
                cluster_resp_data_o[output_cluster][output_word] =
                    owner_data_q[output_cluster][
                        integer'(
                            cluster_emit_hold_slot_q[output_cluster]
                        )
                    ][output_word];
            end

            cluster_response_dequeue[output_cluster] =
                cluster_resp_valid_o[output_cluster]
                && cluster_resp_ready_i[output_cluster];
        end
    end


    /*
     * Reserve one associative owner slot when the external request handshakes
     * into P1.  A retiring slot is available on the same edge.  Duplicate tags
     * and capacity exhaustion are backpressure, not tag-format errors.
     */
    always_comb begin
        p1_cluster_req_valid = '0;
        ingress_owner_found = '0;
        ingress_free_found = '0;
        ingress_admissible = '0;

        for (
            ingress_cluster = 0;
            ingress_cluster < CLUSTER_COUNT;
            ingress_cluster = ingress_cluster + 1
        ) begin
            ingress_cluster_id[ingress_cluster] =
                cluster_req_network_tag_i[ingress_cluster][
                    NETWORK_TAG_W-1 -: CLUSTER_ID_W
                ];

            ingress_cu_id[ingress_cluster] =
                cluster_req_network_tag_i[ingress_cluster][
                    CLUSTER_LOCAL_TAG_W-1 -: CU_ID_W
                ];

            ingress_identity_valid[ingress_cluster] =
                cluster_id_valid(
                    ingress_cluster_id[ingress_cluster]
                )
                && integer'(ingress_cluster_id[ingress_cluster])
                    == ingress_cluster
                && cu_id_valid(ingress_cu_id[ingress_cluster]);

            ingress_free_slot[ingress_cluster] = '0;

            for (
                ingress_slot = 0;
                ingress_slot < OWNER_STORAGE_SLOTS;
                ingress_slot = ingress_slot + 1
            ) begin
                if (
                    owner_state_q[ingress_cluster][ingress_slot]
                        != OWNER_FREE
                    && !(
                        cluster_response_dequeue[ingress_cluster]
                        && integer'(
                            cluster_emit_hold_slot_q[ingress_cluster]
                        ) == ingress_slot
                    )
                    && owner_network_tag_q[
                        ingress_cluster
                    ][ingress_slot]
                        == cluster_req_network_tag_i[ingress_cluster]
                ) begin
                    ingress_owner_found[ingress_cluster] = 1'b1;
                end

                if (
                    !ingress_free_found[ingress_cluster]
                    && (
                        owner_state_q[ingress_cluster][ingress_slot]
                            == OWNER_FREE
                        || (
                            cluster_response_dequeue[ingress_cluster]
                            && integer'(
                                cluster_emit_hold_slot_q[ingress_cluster]
                            ) == ingress_slot
                        )
                    )
                ) begin
                    ingress_free_found[ingress_cluster] = 1'b1;
                    ingress_free_slot[ingress_cluster] =
                        OWNER_SLOT_W'(ingress_slot);
                end
            end

            ingress_admissible[ingress_cluster] =
                ingress_identity_valid[ingress_cluster]
                && !ingress_owner_found[ingress_cluster]
                && ingress_free_found[ingress_cluster];

            p1_cluster_req_valid[ingress_cluster] =
                cluster_req_valid_i[ingress_cluster]
                && ingress_admissible[ingress_cluster];
        end
    end


    /*
     * Keep the P1 ready path out of the admission-decode block.  This makes
     * the registered P1 hold boundary explicit and avoids a false
     * combinational feedback path through the submodule.
     */
    always_comb begin
        cluster_req_ready_o = '0;
        cluster_req_tag_error_o = '0;
        ingress_accept = '0;

        for (
            ingress_output_cluster = 0;
            ingress_output_cluster < CLUSTER_COUNT;
            ingress_output_cluster = ingress_output_cluster + 1
        ) begin
            cluster_req_ready_o[ingress_output_cluster] =
                rst_n
                && p1_cluster_req_ready[ingress_output_cluster]
                && (
                    !cluster_req_valid_i[ingress_output_cluster]
                    || ingress_admissible[ingress_output_cluster]
                );

            cluster_req_tag_error_o[ingress_output_cluster] =
                rst_n
                && cluster_req_valid_i[ingress_output_cluster]
                && (
                    !ingress_identity_valid[ingress_output_cluster]
                    || p1_cluster_req_tag_error[ingress_output_cluster]
                );

            ingress_accept[ingress_output_cluster] =
                cluster_req_valid_i[ingress_output_cluster]
                && cluster_req_ready_o[ingress_output_cluster];
        end
    end


    /*
     * P1's registered holds are exposed unchanged.  The owner lookup is an
     * internal conservation guard: an unowned/corrupt held request cannot be
     * delivered to a slice.
     */
    always_comb begin
        slice_issue_owner_found = '0;
        slice_issue_protocol_valid = '0;
        slice_issue_accept = '0;

        for (
            issue_slice = 0;
            issue_slice < SLICE_COUNT;
            issue_slice = issue_slice + 1
        ) begin
            slice_issue_cluster_id[issue_slice] =
                p1_slice_req_network_tag[issue_slice][
                    NETWORK_TAG_W-1 -: CLUSTER_ID_W
                ];

            slice_issue_owner_slot[issue_slice] = '0;

            if (
                cluster_id_valid(
                    slice_issue_cluster_id[issue_slice]
                )
            ) begin
                for (
                    issue_slot = 0;
                    issue_slot < OWNER_STORAGE_SLOTS;
                    issue_slot = issue_slot + 1
                ) begin
                    if (
                        !slice_issue_owner_found[issue_slice]
                        && owner_state_q[
                            integer'(
                                slice_issue_cluster_id[issue_slice]
                            )
                        ][issue_slot] == OWNER_QUEUED
                        && owner_network_tag_q[
                            integer'(
                                slice_issue_cluster_id[issue_slice]
                            )
                        ][issue_slot]
                            == p1_slice_req_network_tag[issue_slice]
                    ) begin
                        slice_issue_owner_found[issue_slice] = 1'b1;
                        slice_issue_owner_slot[issue_slice] =
                            OWNER_SLOT_W'(issue_slot);
                    end
                end
            end

            if (slice_issue_owner_found[issue_slice]) begin
                slice_issue_protocol_valid[issue_slice] =
                    owner_expected_line_q[
                        integer'(slice_issue_cluster_id[issue_slice])
                    ][integer'(slice_issue_owner_slot[issue_slice])]
                        == p1_slice_req_line_addr[issue_slice]
                    && integer'(
                        owner_expected_home_q[
                            integer'(slice_issue_cluster_id[issue_slice])
                        ][integer'(slice_issue_owner_slot[issue_slice])]
                    ) == issue_slice
                    && integer'(
                        line_to_slice(
                            p1_slice_req_line_addr[issue_slice]
                        )
                    ) == issue_slice;
            end

            slice_req_valid_o[issue_slice] =
                p1_slice_req_valid[issue_slice]
                && slice_issue_protocol_valid[issue_slice];

            slice_req_network_tag_o[issue_slice] =
                p1_slice_req_network_tag[issue_slice];

            slice_req_line_addr_o[issue_slice] =
                p1_slice_req_line_addr[issue_slice];

            p1_slice_req_ready[issue_slice] =
                slice_req_ready_i[issue_slice]
                && (
                    !p1_slice_req_valid[issue_slice]
                    || slice_issue_protocol_valid[issue_slice]
                );

            slice_issue_accept[issue_slice] =
                slice_req_valid_o[issue_slice]
                && slice_req_ready_i[issue_slice];
        end
    end


    /*
     * A correct no-ready response captures directly into its owner slot.
     * QUEUED is accepted only when the matching P1 request issues on this
     * exact edge, supporting a zero-cycle slice response.
     */
    always_comb begin
        response_owner_found = '0;
        response_same_cycle_issue = '0;
        response_capture = '0;
        slice_resp_protocol_error_o = '0;

        for (
            response_slice = 0;
            response_slice < SLICE_COUNT;
            response_slice = response_slice + 1
        ) begin
            response_cluster_id[response_slice] =
                slice_resp_network_tag_i[response_slice][
                    NETWORK_TAG_W-1 -: CLUSTER_ID_W
                ];

            response_cu_id[response_slice] =
                slice_resp_network_tag_i[response_slice][
                    CLUSTER_LOCAL_TAG_W-1 -: CU_ID_W
                ];

            response_identity_valid[response_slice] =
                cluster_id_valid(
                    response_cluster_id[response_slice]
                )
                && cu_id_valid(response_cu_id[response_slice]);

            response_owner_slot[response_slice] = '0;

            if (response_identity_valid[response_slice]) begin
                for (
                    response_slot = 0;
                    response_slot < OWNER_STORAGE_SLOTS;
                    response_slot = response_slot + 1
                ) begin
                    if (
                        !response_owner_found[response_slice]
                        && owner_state_q[
                            integer'(
                                response_cluster_id[response_slice]
                            )
                        ][response_slot] != OWNER_FREE
                        && owner_network_tag_q[
                            integer'(
                                response_cluster_id[response_slice]
                            )
                        ][response_slot]
                            == slice_resp_network_tag_i[response_slice]
                    ) begin
                        response_owner_found[response_slice] = 1'b1;
                        response_owner_slot[response_slice] =
                            OWNER_SLOT_W'(response_slot);
                    end
                end
            end

            for (
                response_issue_slice = 0;
                response_issue_slice < SLICE_COUNT;
                response_issue_slice = response_issue_slice + 1
            ) begin
                if (
                    slice_issue_accept[response_issue_slice]
                    && response_issue_slice == response_slice
                    && p1_slice_req_network_tag[response_issue_slice]
                        == slice_resp_network_tag_i[response_slice]
                    && p1_slice_req_line_addr[response_issue_slice]
                        == slice_resp_line_addr_i[response_slice]
                ) begin
                    response_same_cycle_issue[response_slice] = 1'b1;
                end
            end

            if (
                rst_n
                && slice_resp_valid_i[response_slice]
                && response_identity_valid[response_slice]
                && response_owner_found[response_slice]
            ) begin
                if (
                    (
                        owner_state_q[
                            integer'(
                                response_cluster_id[response_slice]
                            )
                        ][integer'(response_owner_slot[response_slice])]
                            == OWNER_AWAITING
                        || (
                            owner_state_q[
                                integer'(
                                    response_cluster_id[response_slice]
                                )
                            ][integer'(response_owner_slot[response_slice])]
                                == OWNER_QUEUED
                            && response_same_cycle_issue[response_slice]
                        )
                    )
                    && owner_expected_line_q[
                        integer'(response_cluster_id[response_slice])
                    ][integer'(response_owner_slot[response_slice])]
                        == slice_resp_line_addr_i[response_slice]
                    && integer'(
                        owner_expected_home_q[
                            integer'(response_cluster_id[response_slice])
                        ][integer'(response_owner_slot[response_slice])]
                    ) == response_slice
                    && integer'(
                        line_to_slice(
                            slice_resp_line_addr_i[response_slice]
                        )
                    ) == response_slice
                ) begin
                    response_capture[response_slice] = 1'b1;
                end
            end

            slice_resp_protocol_error_o[response_slice] =
                rst_n
                && slice_resp_valid_i[response_slice]
                && !response_capture[response_slice];
        end
    end


    /*
     * Completed owner slots are serviced with an independent RR cursor per
     * cluster.  A chosen owner is marked EMITTING and remains locked while the
     * cluster output is stalled.  The cursor changes only on actual response
     * retirement.
     */
    always_comb begin
        cluster_select_found = '0;

        for (
            select_cluster = 0;
            select_cluster < CLUSTER_COUNT;
            select_cluster = select_cluster + 1
        ) begin
            cluster_select_slot[select_cluster] = '0;
            select_start = 0;
            select_index = 0;

            if (
                rst_n
                && (
                    !cluster_emit_hold_valid_q[select_cluster]
                    || cluster_response_dequeue[select_cluster]
                )
            ) begin
                if (cluster_response_dequeue[select_cluster]) begin
                    select_start =
                        integer'(
                            cluster_emit_hold_slot_q[select_cluster]
                        ) + 1;
                    if (
                        select_start
                        >= CLUSTER_MAX_OUTSTANDING
                    ) begin
                        select_start = 0;
                    end
                end else begin
                    select_start =
                        integer'(cluster_service_rr_q[select_cluster]);
                end

                for (
                    select_offset = 0;
                    select_offset < OWNER_STORAGE_SLOTS;
                    select_offset = select_offset + 1
                ) begin
                    select_index = select_start + select_offset;
                    if (
                        select_index
                        >= CLUSTER_MAX_OUTSTANDING
                    ) begin
                        select_index =
                            select_index - CLUSTER_MAX_OUTSTANDING;
                    end

                    if (
                        !cluster_select_found[select_cluster]
                        && owner_state_q[
                            select_cluster
                        ][select_index] == OWNER_COMPLETE
                    ) begin
                        cluster_select_found[select_cluster] = 1'b1;
                        cluster_select_slot[select_cluster] =
                            OWNER_SLOT_W'(select_index);
                    end
                end
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (
                reset_cluster = 0;
                reset_cluster < CLUSTER_COUNT;
                reset_cluster = reset_cluster + 1
            ) begin
                cluster_emit_hold_valid_q[reset_cluster] <= 1'b0;
                cluster_emit_hold_slot_q[reset_cluster] <= '0;
                cluster_service_rr_q[reset_cluster] <= '0;

                for (
                    reset_slot = 0;
                    reset_slot < OWNER_STORAGE_SLOTS;
                    reset_slot = reset_slot + 1
                ) begin
                    owner_state_q[reset_cluster][reset_slot] <= OWNER_FREE;
                    owner_network_tag_q[reset_cluster][reset_slot] <= '0;
                    owner_expected_line_q[reset_cluster][reset_slot] <= '0;
                    owner_expected_home_q[reset_cluster][reset_slot] <= '0;
                    owner_fault_q[reset_cluster][reset_slot] <= 1'b0;

                    for (
                        reset_word = 0;
                        reset_word < LINE_WORDS;
                        reset_word = reset_word + 1
                    ) begin
                        owner_data_q[
                            reset_cluster
                        ][reset_slot][reset_word] <= '0;
                    end
                end
            end
        end else begin
            /*
             * P1 slice issue moves QUEUED to AWAITING.  A response capture
             * below wins when issue and response share the edge.
             */
            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                if (slice_issue_accept[sequential_slice]) begin
                    owner_state_q[
                        integer'(
                            slice_issue_cluster_id[sequential_slice]
                        )
                    ][
                        integer'(
                            slice_issue_owner_slot[sequential_slice]
                        )
                    ] <= OWNER_AWAITING;
                end
            end

            /* All independent legal no-ready responses capture concurrently. */
            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                if (response_capture[sequential_slice]) begin
                    owner_state_q[
                        integer'(
                            response_cluster_id[sequential_slice]
                        )
                    ][
                        integer'(
                            response_owner_slot[sequential_slice]
                        )
                    ] <= OWNER_COMPLETE;

                    owner_fault_q[
                        integer'(
                            response_cluster_id[sequential_slice]
                        )
                    ][
                        integer'(
                            response_owner_slot[sequential_slice]
                        )
                    ] <= slice_resp_fault_i[sequential_slice];

                    for (
                        sequential_word = 0;
                        sequential_word < LINE_WORDS;
                        sequential_word = sequential_word + 1
                    ) begin
                        owner_data_q[
                            integer'(
                                response_cluster_id[sequential_slice]
                            )
                        ][
                            integer'(
                                response_owner_slot[sequential_slice]
                            )
                        ][sequential_word] <=
                            slice_resp_data_i[
                                sequential_slice
                            ][sequential_word];
                    end
                end
            end

            /* A selected completion becomes the cluster's locked emitter. */
            for (
                sequential_cluster = 0;
                sequential_cluster < CLUSTER_COUNT;
                sequential_cluster = sequential_cluster + 1
            ) begin
                if (cluster_select_found[sequential_cluster]) begin
                    cluster_emit_hold_valid_q[sequential_cluster] <= 1'b1;
                    cluster_emit_hold_slot_q[sequential_cluster] <=
                        cluster_select_slot[sequential_cluster];
                    owner_state_q[sequential_cluster][
                        integer'(cluster_select_slot[sequential_cluster])
                    ] <= OWNER_EMITTING;
                end else if (
                    cluster_response_dequeue[sequential_cluster]
                ) begin
                    cluster_emit_hold_valid_q[sequential_cluster] <= 1'b0;
                end
            end

            /*
             * Retirement frees ownership and alone advances service RR.
             * A same-edge request acquisition below may reuse this slot.
             */
            for (
                sequential_cluster = 0;
                sequential_cluster < CLUSTER_COUNT;
                sequential_cluster = sequential_cluster + 1
            ) begin
                if (cluster_response_dequeue[sequential_cluster]) begin
                    owner_state_q[sequential_cluster][
                        integer'(
                            cluster_emit_hold_slot_q[sequential_cluster]
                        )
                    ] <= OWNER_FREE;

                    if (
                        integer'(
                            cluster_emit_hold_slot_q[sequential_cluster]
                        ) == CLUSTER_MAX_OUTSTANDING - 1
                    ) begin
                        cluster_service_rr_q[sequential_cluster] <= '0;
                    end else begin
                        cluster_service_rr_q[sequential_cluster] <=
                            OWNER_SLOT_W'(
                                integer'(
                                    cluster_emit_hold_slot_q[
                                        sequential_cluster
                                    ]
                                ) + 1
                            );
                    end
                end
            end

            /* Request reservation is last so retire/reuse installs new state. */
            for (
                sequential_cluster = 0;
                sequential_cluster < CLUSTER_COUNT;
                sequential_cluster = sequential_cluster + 1
            ) begin
                if (ingress_accept[sequential_cluster]) begin
                    owner_state_q[sequential_cluster][
                        integer'(ingress_free_slot[sequential_cluster])
                    ] <= OWNER_QUEUED;

                    owner_network_tag_q[sequential_cluster][
                        integer'(ingress_free_slot[sequential_cluster])
                    ] <= cluster_req_network_tag_i[sequential_cluster];

                    owner_expected_line_q[sequential_cluster][
                        integer'(ingress_free_slot[sequential_cluster])
                    ] <= cluster_req_line_addr_i[sequential_cluster];

                    owner_expected_home_q[sequential_cluster][
                        integer'(ingress_free_slot[sequential_cluster])
                    ] <= line_to_slice(
                        cluster_req_line_addr_i[sequential_cluster]
                    );
                end
            end
        end
    end


    generate
        for (
            assertion_cluster = 0;
            assertion_cluster < CLUSTER_COUNT;
            assertion_cluster = assertion_cluster + 1
        ) begin : gen_cluster_assertions
            property malformed_request_cannot_handshake;
                @(posedge clk)
                disable iff (!rst_n)
                cluster_req_valid_i[assertion_cluster]
                && !ingress_identity_valid[assertion_cluster]
                |-> !cluster_req_ready_o[assertion_cluster];
            endproperty

            assert property (malformed_request_cannot_handshake)
                else $fatal(
                    1,
                    "MC_NOC_P2 malformed request handshook"
                );


            property cluster_response_stable_under_stall;
                @(posedge clk)
                disable iff (!rst_n)
                cluster_resp_valid_o[assertion_cluster]
                && !cluster_resp_ready_i[assertion_cluster]
                |=> cluster_resp_valid_o[assertion_cluster]
                    && $stable(
                        cluster_resp_network_tag_o[assertion_cluster]
                    )
                    && $stable(
                        cluster_resp_line_addr_o[assertion_cluster]
                    )
                    && $stable(
                        cluster_resp_fault_o[assertion_cluster]
                    );
            endproperty

            assert property (cluster_response_stable_under_stall)
                else $fatal(
                    1,
                    "MC_NOC_P2 cluster response changed under stall"
                );


            for (
                assertion_word = 0;
                assertion_word < LINE_WORDS;
                assertion_word = assertion_word + 1
            ) begin : gen_response_word_assertions
                property cluster_response_word_stable_under_stall;
                    @(posedge clk)
                    disable iff (!rst_n)
                    cluster_resp_valid_o[assertion_cluster]
                    && !cluster_resp_ready_i[assertion_cluster]
                    |=> $stable(
                        cluster_resp_data_o[
                            assertion_cluster
                        ][assertion_word]
                    );
                endproperty

                assert property (
                    cluster_response_word_stable_under_stall
                )
                    else $fatal(
                        1,
                        "MC_NOC_P2 response data changed under stall"
                    );
            end
        end

        for (
            assertion_slice = 0;
            assertion_slice < SLICE_COUNT;
            assertion_slice = assertion_slice + 1
        ) begin : gen_slice_assertions
            property held_p1_request_has_owner;
                @(posedge clk)
                disable iff (!rst_n)
                p1_slice_req_valid[assertion_slice]
                |-> slice_issue_protocol_valid[assertion_slice];
            endproperty

            assert property (held_p1_request_has_owner)
                else $fatal(
                    1,
                    "MC_NOC_P2 P1 request lost ownership"
                );
        end
    endgenerate


    property reset_clears_cluster_emit_holds;
        @(posedge clk)
        !rst_n
        |=> cluster_emit_hold_valid_q == '0;
    endproperty

    assert property (reset_clears_cluster_emit_holds)
        else $fatal(
            1,
            "MC_NOC_P2 reset did not clear cluster response holds"
        );

endmodule
