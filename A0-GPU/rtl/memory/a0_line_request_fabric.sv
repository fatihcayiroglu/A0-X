`timescale 1ns/1ps

/*
 * A0 RTL9D-1 requester-tagged line-request fabric foundation.
 *
 * This block intentionally remains isolated from the production core.
 *
 * Contract:
 *   - CLIENT_COUNT independent upstream line-request clients
 *   - each client owns a local opaque tag
 *   - one downstream ready/valid line-request port
 *   - downstream global tag is {client_id, local_tag}
 *   - round-robin request arbitration
 *   - accepted client request is held stable across downstream backpressure
 *   - downstream responses may return out of order
 *   - response global tag selects exactly one client
 *   - original local tag, line address, fault and data are preserved
 *   - invalid encoded requester IDs are rejected without response fanout
 *
 * No L2 storage, coherence, translation, NoC, or memory-controller policy is
 * implemented here.
 */
module a0_line_request_fabric #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer LINE_ADDR_W = 29,
    parameter integer LINE_WORDS = 8,

    parameter integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),

    parameter integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W
) (
    input logic clk,
    input logic rst_n,

    /*
     * Client request ports.
     *
     * Port index is the requester/client identity.
     */
    input logic [CLIENT_COUNT-1:0] client_req_valid_i,
    output logic [CLIENT_COUNT-1:0] client_req_ready_o,

    input logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i [0:CLIENT_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i [0:CLIENT_COUNT-1],

    /*
     * Shared downstream line-request port.
     */
    output logic line_req_valid_o,
    input logic line_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        line_req_global_tag_o,

    output logic [LINE_ADDR_W-1:0]
        line_req_line_addr_o,

    /*
     * Shared downstream line-response input.
     *
     * There is intentionally no response ready/backpressure in this
     * foundation, matching the existing line-response contract.
     */
    input logic line_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        line_resp_global_tag_i,

    input logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_i,

    input logic line_resp_fault_i,

    input logic [31:0]
        line_resp_data_i [0:LINE_WORDS-1],

    /*
     * Demultiplexed client responses.
     */
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

    /*
     * Malformed downstream response requester ID.
     */
    output logic line_resp_tag_error_o
);

    logic [CLIENT_ID_W-1:0] rr_q;

    logic hold_valid_q;
    logic [CLIENT_ID_W-1:0] hold_client_q;
    logic [LOCAL_TAG_W-1:0] hold_local_tag_q;
    logic [LINE_ADDR_W-1:0] hold_line_addr_q;

    logic slot_available;

    logic grant_found;
    logic [CLIENT_ID_W-1:0] grant_client;

    logic request_accept;

    logic [CLIENT_ID_W-1:0] resp_client_id;
    logic [LOCAL_TAG_W-1:0] resp_local_tag;
    logic resp_client_valid;

    integer grant_scan_offset;
    integer grant_scan_client;
    logic [CLIENT_ID_W-1:0] response_client;

    integer response_output_client;
    integer response_word;


    function automatic logic client_id_valid(
        input logic [CLIENT_ID_W-1:0] client_id
    );
        client_id_valid =
            integer'(client_id) < CLIENT_COUNT;
    endfunction


    always_comb begin
        /*
         * A slot is available when empty, or when the currently-held request
         * will be consumed on this cycle.
         */
        slot_available =
            rst_n
            && (
                !hold_valid_q
                || line_req_ready_i
            );

        grant_found = 1'b0;
        grant_client = '0;
        grant_scan_client = 0;

        client_req_ready_o = '0;

        if (slot_available) begin
            for (
                grant_scan_offset = 0;
                grant_scan_offset < CLIENT_COUNT;
                grant_scan_offset = grant_scan_offset + 1
            ) begin
                grant_scan_client =
                    integer'(rr_q)
                    + grant_scan_offset;

                if (
                    grant_scan_client
                    >= CLIENT_COUNT
                ) begin
                    grant_scan_client =
                        grant_scan_client
                        - CLIENT_COUNT;
                end

                if (
                    !grant_found
                    && client_req_valid_i[
                        grant_scan_client
                    ]
                ) begin
                    grant_found = 1'b1;
                    grant_client =
                        CLIENT_ID_W'(
                            grant_scan_client
                        );
                end
            end
        end

        if (grant_found) begin
            client_req_ready_o[
                integer'(grant_client)
            ] = 1'b1;
        end

        request_accept =
            grant_found
            && client_req_valid_i[
                integer'(grant_client)
            ]
            && client_req_ready_o[
                integer'(grant_client)
            ];

        /*
         * Downstream request payload is driven only from registered holding
         * state, so it remains stable throughout arbitrary backpressure.
         */
        line_req_valid_o =
            rst_n
            && hold_valid_q;

        line_req_global_tag_o = {
            hold_client_q,
            hold_local_tag_q
        };

        line_req_line_addr_o =
            hold_line_addr_q;

        /*
         * Response tag decode.
         */
        resp_client_id =
            line_resp_global_tag_i[
                GLOBAL_TAG_W-1
                -:
                CLIENT_ID_W
            ];

        resp_local_tag =
            line_resp_global_tag_i[
                LOCAL_TAG_W-1:0
            ];

        resp_client_valid =
            client_id_valid(
                resp_client_id
            );

        line_resp_tag_error_o =
            rst_n
            && line_resp_valid_i
            && !resp_client_valid;

        client_resp_valid_o = '0;

        response_client = 0;

        for (
            response_output_client = 0;
            response_output_client < CLIENT_COUNT;
            response_output_client =
                response_output_client + 1
        ) begin
            client_resp_local_tag_o[
                response_output_client
            ] = '0;

            client_resp_line_addr_o[
                response_output_client
            ] = '0;

            client_resp_fault_o[
                response_output_client
            ] = 1'b0;

            for (
                response_word = 0;
                response_word < LINE_WORDS;
                response_word = response_word + 1
            ) begin
                client_resp_data_o[
                    response_output_client
                ][response_word] = '0;
            end
        end

        if (
            rst_n
            && line_resp_valid_i
            && resp_client_valid
        ) begin
            response_client =
                resp_client_id;

            client_resp_valid_o[
                response_client
            ] = 1'b1;

            client_resp_local_tag_o[
                response_client
            ] = resp_local_tag;

            client_resp_line_addr_o[
                response_client
            ] = line_resp_line_addr_i;

            client_resp_fault_o[
                response_client
            ] = line_resp_fault_i;

            for (
                response_word = 0;
                response_word < LINE_WORDS;
                response_word = response_word + 1
            ) begin
                client_resp_data_o[
                    response_client
                ][response_word] =
                    line_resp_data_i[
                        response_word
                    ];
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rr_q <= '0;

            hold_valid_q <= 1'b0;
            hold_client_q <= '0;
            hold_local_tag_q <= '0;
            hold_line_addr_q <= '0;
        end else begin
            /*
             * Retire the held request when the downstream accepts it.
             */
            if (
                hold_valid_q
                && line_req_ready_i
            ) begin
                hold_valid_q <= 1'b0;
            end

            /*
             * A newly accepted client request replaces an empty slot or the
             * request being retired on this same edge.
             */
            if (request_accept) begin
                hold_valid_q <= 1'b1;

                hold_client_q <=
                    grant_client;

                hold_local_tag_q <=
                    client_req_local_tag_i[
                        integer'(grant_client)
                    ];

                hold_line_addr_q <=
                    client_req_line_addr_i[
                        integer'(grant_client)
                    ];

                if (
                    integer'(grant_client)
                    == CLIENT_COUNT - 1
                ) begin
                    rr_q <= '0;
                end else begin
                    rr_q <=
                        grant_client
                        + CLIENT_ID_W'(1);
                end
            end
        end
    end

endmodule
