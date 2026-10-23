`timescale 1ns/1ps

/*
 * A0 sliced-L2 line-routing foundation.
 *
 * This block is intentionally isolated from production CU wiring. It replaces
 * the single-downstream bottleneck of a0_line_request_fabric with one
 * independently-arbitrated request channel per L2 slice while preserving the
 * current requester tag shape {client_id, local_tag}.
 *
 * Important contract points:
 *   - every client request hashes to exactly one power-of-two slice;
 *   - every slice owns an independent round-robin arbiter and one-entry hold;
 *   - unrelated slices may accept requests concurrently;
 *   - accepted request payload remains stable across slice backpressure;
 *   - a local tag remains busy until its response is emitted to the client;
 *   - responses from several slices may arrive in the same cycle;
 *   - each client owns CLIENT_MAX_OUTSTANDING response slots, so simultaneous
 *     no-ready slice responses are captured without loss;
 *   - response client/tag/line/home-slice are checked fail-closed;
 *   - the L2 keeps the global tag opaque.
 *
 * This is a logical routing foundation, not a physical mesh/ring NoC and not a
 * cache-coherence protocol.
 */
module a0_line_slice_fabric #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer LINE_ADDR_W = 29,
    parameter integer LINE_WORDS = 8,
    parameter integer SLICE_COUNT = 4,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer SLICE_HASH_SHIFT = 8,

    parameter integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),

    parameter integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W,

    parameter integer SLICE_ID_W =
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),

    parameter integer RESP_SLOT_W =
        (CLIENT_MAX_OUTSTANDING <= 1)
            ? 1
            : $clog2(CLIENT_MAX_OUTSTANDING),

    parameter integer INFLIGHT_COUNT_W =
        (CLIENT_MAX_OUTSTANDING <= 1)
            ? 1
            : $clog2(CLIENT_MAX_OUTSTANDING + 1),

    parameter integer LOCAL_TAG_COUNT =
        (1 << LOCAL_TAG_W)
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

    output logic [SLICE_COUNT-1:0]
        slice_req_valid_o,

    input logic [SLICE_COUNT-1:0]
        slice_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        slice_req_global_tag_o [0:SLICE_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        slice_req_line_addr_o [0:SLICE_COUNT-1],

    input logic [SLICE_COUNT-1:0]
        slice_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        slice_resp_global_tag_i [0:SLICE_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        slice_resp_line_addr_i [0:SLICE_COUNT-1],

    input logic
        slice_resp_fault_i [0:SLICE_COUNT-1],

    input logic [31:0]
        slice_resp_data_i
            [0:SLICE_COUNT-1]
            [0:LINE_WORDS-1],

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

    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o
);

    logic [CLIENT_ID_W-1:0]
        slice_rr_q [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_hold_valid_q;

    logic [CLIENT_ID_W-1:0]
        slice_hold_client_q [0:SLICE_COUNT-1];

    logic [LOCAL_TAG_W-1:0]
        slice_hold_local_tag_q [0:SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_hold_line_q [0:SLICE_COUNT-1];

    logic tag_busy_q
        [0:CLIENT_COUNT-1]
        [0:LOCAL_TAG_COUNT-1];

    logic tag_awaiting_q
        [0:CLIENT_COUNT-1]
        [0:LOCAL_TAG_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        tag_line_q
            [0:CLIENT_COUNT-1]
            [0:LOCAL_TAG_COUNT-1];

    logic [INFLIGHT_COUNT_W-1:0]
        client_inflight_q [0:CLIENT_COUNT-1];

    logic response_slot_valid_q
        [0:CLIENT_COUNT-1]
        [0:CLIENT_MAX_OUTSTANDING-1];

    logic [LOCAL_TAG_W-1:0]
        response_slot_local_tag_q
            [0:CLIENT_COUNT-1]
            [0:CLIENT_MAX_OUTSTANDING-1];

    logic [LINE_ADDR_W-1:0]
        response_slot_line_q
            [0:CLIENT_COUNT-1]
            [0:CLIENT_MAX_OUTSTANDING-1];

    logic response_slot_fault_q
        [0:CLIENT_COUNT-1]
        [0:CLIENT_MAX_OUTSTANDING-1];

    logic [31:0]
        response_slot_data_q
            [0:CLIENT_COUNT-1]
            [0:CLIENT_MAX_OUTSTANDING-1]
            [0:LINE_WORDS-1];

    logic [SLICE_ID_W-1:0]
        client_target_slice [0:CLIENT_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_slot_available;

    logic [SLICE_COUNT-1:0]
        slice_grant_found;

    logic [CLIENT_ID_W-1:0]
        slice_grant_client [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_request_accept;

    logic [CLIENT_COUNT-1:0]
        client_request_accept;

    logic [CLIENT_COUNT-1:0]
        client_output_slot_found;

    logic [RESP_SLOT_W-1:0]
        client_output_slot [0:CLIENT_COUNT-1];

    logic [SLICE_COUNT-1:0]
        slice_response_accept;

    logic [CLIENT_ID_W-1:0]
        slice_response_client [0:SLICE_COUNT-1];

    logic [LOCAL_TAG_W-1:0]
        slice_response_local_tag [0:SLICE_COUNT-1];

    logic [RESP_SLOT_W-1:0]
        slice_response_slot [0:SLICE_COUNT-1];

    logic response_slot_reserved
        [0:CLIENT_COUNT-1]
        [0:CLIENT_MAX_OUTSTANDING-1];

    logic response_tag_claimed
        [0:CLIENT_COUNT-1]
        [0:LOCAL_TAG_COUNT-1];

    integer request_client_index;
    integer request_slice_index;
    integer scan_offset;
    integer scan_client;
    integer output_client_index;
    integer output_response_slot_index;
    integer response_client_index;
    integer response_slice_index;
    integer response_slot_index;
    integer response_tag_index;
    integer response_word;
    integer reset_client;
    integer reset_slice;
    integer reset_tag;
    integer reset_slot;
    integer reset_word;
    integer sequential_client;
    integer sequential_slice;
    integer sequential_word;


    function automatic logic client_id_valid(
        input logic [CLIENT_ID_W-1:0] client_id
    );
        client_id_valid =
            integer'(client_id) < CLIENT_COUNT;
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
        if (CLIENT_COUNT < 1) begin
            $fatal(1, "SLICED_L2 CLIENT_COUNT must be >= 1");
        end
        if (LOCAL_TAG_W < 1) begin
            $fatal(1, "SLICED_L2 LOCAL_TAG_W must be >= 1");
        end
        if (LINE_ADDR_W < 1) begin
            $fatal(1, "SLICED_L2 LINE_ADDR_W must be >= 1");
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "SLICED_L2 LINE_WORDS must be >= 1");
        end
        if (SLICE_COUNT < 1) begin
            $fatal(1, "SLICED_L2 SLICE_COUNT must be >= 1");
        end
        if ((SLICE_COUNT & (SLICE_COUNT - 1)) != 0) begin
            $fatal(1, "SLICED_L2 SLICE_COUNT must be a power of two");
        end
        if (CLIENT_MAX_OUTSTANDING < 1) begin
            $fatal(1, "SLICED_L2 CLIENT_MAX_OUTSTANDING must be >= 1");
        end
        if (CLIENT_MAX_OUTSTANDING > LOCAL_TAG_COUNT) begin
            $fatal(
                1,
                "SLICED_L2 CLIENT_MAX_OUTSTANDING exceeds local tag space"
            );
        end
        if (CLIENT_ID_W != ((CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT))) begin
            $fatal(1, "SLICED_L2 CLIENT_ID_W inconsistent");
        end
        if (GLOBAL_TAG_W != CLIENT_ID_W + LOCAL_TAG_W) begin
            $fatal(1, "SLICED_L2 GLOBAL_TAG_W inconsistent");
        end
        if (SLICE_ID_W != ((SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT))) begin
            $fatal(1, "SLICED_L2 SLICE_ID_W inconsistent");
        end
        if (SLICE_COUNT > 1 && SLICE_HASH_SHIFT >= LINE_ADDR_W) begin
            $fatal(1, "SLICED_L2 SLICE_HASH_SHIFT must be below LINE_ADDR_W");
        end
    end


    always_comb begin
        client_req_ready_o = '0;
        client_request_accept = '0;

        for (
            request_client_index = 0;
            request_client_index < CLIENT_COUNT;
            request_client_index = request_client_index + 1
        ) begin
            client_target_slice[request_client_index] =
                line_to_slice(client_req_line_addr_i[request_client_index]);
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

            slice_grant_found[request_slice_index] = 1'b0;
            slice_grant_client[request_slice_index] = '0;
            scan_client = 0;

            if (slice_slot_available[request_slice_index]) begin
                for (
                    scan_offset = 0;
                    scan_offset < CLIENT_COUNT;
                    scan_offset = scan_offset + 1
                ) begin
                    scan_client =
                        integer'(slice_rr_q[request_slice_index])
                        + scan_offset;

                    if (scan_client >= CLIENT_COUNT) begin
                        scan_client = scan_client - CLIENT_COUNT;
                    end

                    if (
                        !slice_grant_found[request_slice_index]
                        && client_req_valid_i[scan_client]
                        && integer'(client_target_slice[scan_client])
                            == request_slice_index
                        && (
                            !tag_busy_q[scan_client][
                                integer'(client_req_local_tag_i[scan_client])
                            ]
                            || (
                                client_resp_valid_o[scan_client]
                                && client_resp_local_tag_o[scan_client]
                                    == client_req_local_tag_i[scan_client]
                            )
                        )
                        && (
                            integer'(client_inflight_q[scan_client])
                                < CLIENT_MAX_OUTSTANDING
                            || client_resp_valid_o[scan_client]
                        )
                    ) begin
                        slice_grant_found[request_slice_index] = 1'b1;
                        slice_grant_client[request_slice_index] =
                            CLIENT_ID_W'(scan_client);
                    end
                end
            end

            if (slice_grant_found[request_slice_index]) begin
                client_req_ready_o[
                    integer'(slice_grant_client[request_slice_index])
                ] = 1'b1;
            end

            slice_request_accept[request_slice_index] =
                slice_grant_found[request_slice_index]
                && client_req_valid_i[
                    integer'(slice_grant_client[request_slice_index])
                ]
                && client_req_ready_o[
                    integer'(slice_grant_client[request_slice_index])
                ];

            if (slice_request_accept[request_slice_index]) begin
                client_request_accept[
                    integer'(slice_grant_client[request_slice_index])
                ] = 1'b1;
            end
        end

        for (
            request_slice_index = 0;
            request_slice_index < SLICE_COUNT;
            request_slice_index = request_slice_index + 1
        ) begin
            slice_req_valid_o[request_slice_index] =
                rst_n && slice_hold_valid_q[request_slice_index];

            slice_req_global_tag_o[request_slice_index] = {
                slice_hold_client_q[request_slice_index],
                slice_hold_local_tag_q[request_slice_index]
            };

            slice_req_line_addr_o[request_slice_index] =
                slice_hold_line_q[request_slice_index];
        end
    end


    always_comb begin
        client_resp_valid_o = '0;

        for (
            output_client_index = 0;
            output_client_index < CLIENT_COUNT;
            output_client_index = output_client_index + 1
        ) begin
            client_output_slot_found[output_client_index] = 1'b0;
            client_output_slot[output_client_index] = '0;

            client_resp_local_tag_o[output_client_index] = '0;
            client_resp_line_addr_o[output_client_index] = '0;
            client_resp_fault_o[output_client_index] = 1'b0;

            for (
                response_word = 0;
                response_word < LINE_WORDS;
                response_word = response_word + 1
            ) begin
                client_resp_data_o[output_client_index][response_word] = '0;
            end

            for (
                output_response_slot_index = 0;
                output_response_slot_index < CLIENT_MAX_OUTSTANDING;
                output_response_slot_index = output_response_slot_index + 1
            ) begin
                if (
                    !client_output_slot_found[output_client_index]
                    && response_slot_valid_q[
                        output_client_index
                    ][output_response_slot_index]
                ) begin
                    client_output_slot_found[output_client_index] = 1'b1;
                    client_output_slot[output_client_index] =
                        RESP_SLOT_W'(output_response_slot_index);
                end
            end

            if (
                rst_n
                && client_output_slot_found[output_client_index]
            ) begin
                client_resp_valid_o[output_client_index] = 1'b1;
                client_resp_local_tag_o[output_client_index] =
                    response_slot_local_tag_q[
                        output_client_index
                    ][integer'(client_output_slot[output_client_index])];
                client_resp_line_addr_o[output_client_index] =
                    response_slot_line_q[
                        output_client_index
                    ][integer'(client_output_slot[output_client_index])];
                client_resp_fault_o[output_client_index] =
                    response_slot_fault_q[
                        output_client_index
                    ][integer'(client_output_slot[output_client_index])];

                for (
                    response_word = 0;
                    response_word < LINE_WORDS;
                    response_word = response_word + 1
                ) begin
                    client_resp_data_o[
                        output_client_index
                    ][response_word] =
                        response_slot_data_q[
                            output_client_index
                        ][integer'(client_output_slot[output_client_index])][
                            response_word
                        ];
                end
            end
        end
    end


    always_comb begin
        line_resp_tag_error_o = 1'b0;
        line_resp_overflow_o = 1'b0;
        slice_response_accept = '0;

        for (
            response_client_index = 0;
            response_client_index < CLIENT_COUNT;
            response_client_index = response_client_index + 1
        ) begin
            for (
                response_slot_index = 0;
                response_slot_index < CLIENT_MAX_OUTSTANDING;
                response_slot_index = response_slot_index + 1
            ) begin
                response_slot_reserved[
                    response_client_index
                ][response_slot_index] =
                    response_slot_valid_q[
                        response_client_index
                    ][response_slot_index];
            end

            if (client_output_slot_found[response_client_index]) begin
                response_slot_reserved[
                    response_client_index
                ][integer'(client_output_slot[response_client_index])] = 1'b0;
            end

            for (
                response_tag_index = 0;
                response_tag_index < LOCAL_TAG_COUNT;
                response_tag_index = response_tag_index + 1
            ) begin
                response_tag_claimed[response_client_index][response_tag_index] = 1'b0;
            end
        end

        for (
            response_slice_index = 0;
            response_slice_index < SLICE_COUNT;
            response_slice_index = response_slice_index + 1
        ) begin
            logic [CLIENT_ID_W-1:0] decoded_client;
            logic [LOCAL_TAG_W-1:0] decoded_local_tag;
            logic decoded_valid;
            logic response_valid_for_request;
            logic free_slot_found;
            decoded_client =
                slice_resp_global_tag_i[response_slice_index][
                    GLOBAL_TAG_W-1 -: CLIENT_ID_W
                ];
            decoded_local_tag =
                slice_resp_global_tag_i[response_slice_index][LOCAL_TAG_W-1:0];
            decoded_valid = client_id_valid(decoded_client);
            slice_response_client[response_slice_index] = decoded_client;
            slice_response_local_tag[response_slice_index] = decoded_local_tag;
            slice_response_slot[response_slice_index] = '0;
            free_slot_found = 1'b0;
            response_valid_for_request = 1'b0;

            if (
                rst_n
                && slice_resp_valid_i[response_slice_index]
                && decoded_valid
            ) begin
                response_valid_for_request =
                    tag_busy_q[integer'(decoded_client)][integer'(decoded_local_tag)]
                    && tag_awaiting_q[
                        integer'(decoded_client)
                    ][integer'(decoded_local_tag)]
                    && !response_tag_claimed[
                        integer'(decoded_client)
                    ][integer'(decoded_local_tag)]
                    && tag_line_q[
                        integer'(decoded_client)
                    ][integer'(decoded_local_tag)]
                        == slice_resp_line_addr_i[response_slice_index]
                    && integer'(
                        line_to_slice(slice_resp_line_addr_i[response_slice_index])
                    ) == response_slice_index;
            end

            if (
                rst_n
                && slice_resp_valid_i[response_slice_index]
                && !response_valid_for_request
            ) begin
                line_resp_tag_error_o = 1'b1;
            end

            if (response_valid_for_request) begin
                for (
                    response_slot_index = 0;
                    response_slot_index < CLIENT_MAX_OUTSTANDING;
                    response_slot_index = response_slot_index + 1
                ) begin
                    if (
                        !free_slot_found
                        && !response_slot_reserved[
                            integer'(decoded_client)
                        ][response_slot_index]
                    ) begin
                        free_slot_found = 1'b1;
                        slice_response_slot[response_slice_index] =
                            RESP_SLOT_W'(response_slot_index);
                    end
                end

                if (free_slot_found) begin
                    slice_response_accept[response_slice_index] = 1'b1;
                    response_slot_reserved[
                        integer'(decoded_client)
                    ][integer'(slice_response_slot[response_slice_index])] = 1'b1;
                    response_tag_claimed[
                        integer'(decoded_client)
                    ][integer'(decoded_local_tag)] = 1'b1;
                end else begin
                    line_resp_overflow_o = 1'b1;
                end
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (
                reset_slice = 0;
                reset_slice < SLICE_COUNT;
                reset_slice = reset_slice + 1
            ) begin
                slice_rr_q[reset_slice] <= '0;
                slice_hold_valid_q[reset_slice] <= 1'b0;
                slice_hold_client_q[reset_slice] <= '0;
                slice_hold_local_tag_q[reset_slice] <= '0;
                slice_hold_line_q[reset_slice] <= '0;
            end

            for (
                reset_client = 0;
                reset_client < CLIENT_COUNT;
                reset_client = reset_client + 1
            ) begin
                client_inflight_q[reset_client] <= '0;

                for (
                    reset_tag = 0;
                    reset_tag < LOCAL_TAG_COUNT;
                    reset_tag = reset_tag + 1
                ) begin
                    tag_busy_q[reset_client][reset_tag] <= 1'b0;
                    tag_awaiting_q[reset_client][reset_tag] <= 1'b0;
                    tag_line_q[reset_client][reset_tag] <= '0;
                end

                for (
                    reset_slot = 0;
                    reset_slot < CLIENT_MAX_OUTSTANDING;
                    reset_slot = reset_slot + 1
                ) begin
                    response_slot_valid_q[
                        reset_client
                    ][reset_slot] <= 1'b0;
                    response_slot_local_tag_q[
                        reset_client
                    ][reset_slot] <= '0;
                    response_slot_line_q[
                        reset_client
                    ][reset_slot] <= '0;
                    response_slot_fault_q[
                        reset_client
                    ][reset_slot] <= 1'b0;

                    for (
                        reset_word = 0;
                        reset_word < LINE_WORDS;
                        reset_word = reset_word + 1
                    ) begin
                        response_slot_data_q[
                            reset_client
                        ][reset_slot][reset_word] <= '0;
                    end
                end
            end
        end else begin
            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                if (
                    slice_hold_valid_q[sequential_slice]
                    && slice_req_ready_i[sequential_slice]
                ) begin
                    slice_hold_valid_q[sequential_slice] <= 1'b0;
                end

                if (slice_request_accept[sequential_slice]) begin
                    slice_hold_valid_q[sequential_slice] <= 1'b1;
                    slice_hold_client_q[sequential_slice] <=
                        slice_grant_client[sequential_slice];
                    slice_hold_local_tag_q[sequential_slice] <=
                        client_req_local_tag_i[
                            integer'(slice_grant_client[sequential_slice])
                        ];
                    slice_hold_line_q[sequential_slice] <=
                        client_req_line_addr_i[
                            integer'(slice_grant_client[sequential_slice])
                        ];

                    if (
                        integer'(slice_grant_client[sequential_slice])
                        == CLIENT_COUNT - 1
                    ) begin
                        slice_rr_q[sequential_slice] <= '0;
                    end else begin
                        slice_rr_q[sequential_slice] <=
                            CLIENT_ID_W'(
                                integer'(slice_grant_client[sequential_slice])
                                + 1
                            );
                    end
                end
            end

            for (
                sequential_client = 0;
                sequential_client < CLIENT_COUNT;
                sequential_client = sequential_client + 1
            ) begin
                if (client_resp_valid_o[sequential_client]) begin
                    response_slot_valid_q[
                        sequential_client
                    ][integer'(client_output_slot[sequential_client])] <= 1'b0;
                    tag_busy_q[
                        sequential_client
                    ][integer'(
                        response_slot_local_tag_q[
                            sequential_client
                        ][integer'(client_output_slot[sequential_client])]
                    )] <= 1'b0;
                    tag_awaiting_q[
                        sequential_client
                    ][integer'(
                        response_slot_local_tag_q[
                            sequential_client
                        ][integer'(client_output_slot[sequential_client])]
                    )] <= 1'b0;
                end

                if (
                    client_request_accept[sequential_client]
                    && !client_resp_valid_o[sequential_client]
                ) begin
                    client_inflight_q[sequential_client] <=
                        client_inflight_q[sequential_client] + 1'b1;
                end else if (
                    !client_request_accept[sequential_client]
                    && client_resp_valid_o[sequential_client]
                ) begin
                    client_inflight_q[sequential_client] <=
                        client_inflight_q[sequential_client] - 1'b1;
                end
            end

            for (
                sequential_slice = 0;
                sequential_slice < SLICE_COUNT;
                sequential_slice = sequential_slice + 1
            ) begin
                if (slice_request_accept[sequential_slice]) begin
                    tag_busy_q[
                        integer'(slice_grant_client[sequential_slice])
                    ][integer'(client_req_local_tag_i[
                        integer'(slice_grant_client[sequential_slice])
                    ])] <= 1'b1;
                    tag_awaiting_q[
                        integer'(slice_grant_client[sequential_slice])
                    ][integer'(client_req_local_tag_i[
                        integer'(slice_grant_client[sequential_slice])
                    ])] <= 1'b1;
                    tag_line_q[
                        integer'(slice_grant_client[sequential_slice])
                    ][integer'(client_req_local_tag_i[
                        integer'(slice_grant_client[sequential_slice])
                    ])] <= client_req_line_addr_i[
                        integer'(slice_grant_client[sequential_slice])
                    ];
                end

                if (slice_response_accept[sequential_slice]) begin
                    response_slot_valid_q[
                        integer'(slice_response_client[sequential_slice])
                    ][integer'(slice_response_slot[sequential_slice])] <= 1'b1;
                    response_slot_local_tag_q[
                        integer'(slice_response_client[sequential_slice])
                    ][integer'(slice_response_slot[sequential_slice])] <=
                        slice_response_local_tag[sequential_slice];
                    response_slot_line_q[
                        integer'(slice_response_client[sequential_slice])
                    ][integer'(slice_response_slot[sequential_slice])] <=
                        slice_resp_line_addr_i[sequential_slice];
                    response_slot_fault_q[
                        integer'(slice_response_client[sequential_slice])
                    ][integer'(slice_response_slot[sequential_slice])] <=
                        slice_resp_fault_i[sequential_slice];

                    for (
                        sequential_word = 0;
                        sequential_word < LINE_WORDS;
                        sequential_word = sequential_word + 1
                    ) begin
                        response_slot_data_q[
                            integer'(slice_response_client[sequential_slice])
                        ][integer'(slice_response_slot[sequential_slice])][
                            sequential_word
                        ] <= slice_resp_data_i[
                            sequential_slice
                        ][sequential_word];
                    end

                    tag_awaiting_q[
                        integer'(slice_response_client[sequential_slice])
                    ][integer'(slice_response_local_tag[sequential_slice])] <= 1'b0;
                end
            end
        end
    end

endmodule
