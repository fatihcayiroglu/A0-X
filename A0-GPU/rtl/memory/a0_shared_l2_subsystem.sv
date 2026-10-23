`timescale 1ns/1ps

/*
 * A0 RTL9D-3 requester-tagged fabric + shared-L2 integration foundation.
 *
 * This wrapper composes the closed RTL9D-1 line fabric with the closed
 * RTL9D-2 shared L2 without modifying either primitive.
 *
 * Store traffic does not pass through the line fabric. Per-client physical
 * store observations are flattened into the existing shared-L2 store observer.
 */
module a0_shared_l2_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,

    parameter integer STORE_LANES_PER_CLIENT = 32,

    parameter integer LINE_WORDS = 8,

    parameter integer L2_SET_COUNT = 256,
    parameter integer L2_MISS_COUNT = 16,

    parameter integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1)
            ? 1
            : $clog2(CLIENT_COUNT),

    parameter integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1)
            ? 0
            : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W
) (
    input logic clk,
    input logic rst_n,

    /*
     * Per-client requester-tagged line interface.
     */
    input logic [CLIENT_COUNT-1:0]
        client_req_valid_i,

    output logic [CLIENT_COUNT-1:0]
        client_req_ready_o,

    input logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i
            [0:CLIENT_COUNT-1],

    input logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i
            [0:CLIENT_COUNT-1],

    output logic [CLIENT_COUNT-1:0]
        client_resp_valid_o,

    output logic [LOCAL_TAG_W-1:0]
        client_resp_local_tag_o
            [0:CLIENT_COUNT-1],

    output logic [LINE_ADDR_W-1:0]
        client_resp_line_addr_o
            [0:CLIENT_COUNT-1],

    output logic
        client_resp_fault_o
            [0:CLIENT_COUNT-1],

    output logic [31:0]
        client_resp_data_o
            [0:CLIENT_COUNT-1]
            [0:LINE_WORDS-1],

    /*
     * Physical-store observation from each client.
     */
    input logic [CLIENT_COUNT-1:0]
        client_store_valid_i,

    input logic [STORE_LANES_PER_CLIENT-1:0]
        client_store_lane_mask_i
            [0:CLIENT_COUNT-1],

    input logic [31:0]
        client_store_word_addr_i
            [0:CLIENT_COUNT-1]
            [0:STORE_LANES_PER_CLIENT-1],

    /*
     * Shared external line backend.
     */
    output logic line_mem_req_valid_o,
    input logic line_mem_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        line_mem_req_global_tag_o,

    output logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o,

    input logic line_mem_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        line_mem_resp_global_tag_i,

    input logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i,

    input logic line_mem_resp_fault_i,

    input logic [31:0]
        line_mem_resp_data_i
            [0:LINE_WORDS-1],

    /*
     * Invalid requester encoding returned from the downstream response path.
     */
    output logic line_resp_tag_error_o
);

    localparam integer L2_STORE_LANES =
        CLIENT_COUNT
        * STORE_LANES_PER_CLIENT;

    localparam integer EXPECTED_CLIENT_ID_W =
        (CLIENT_COUNT <= 1)
            ? 1
            : $clog2(CLIENT_COUNT);

    localparam integer EXPECTED_GLOBAL_TAG_W =
        CLIENT_ID_W
        + LOCAL_TAG_W;

    localparam integer EXPECTED_LINE_ADDR_W =
        32
        - (
            (LINE_WORDS <= 1)
                ? 0
                : $clog2(LINE_WORDS)
        );


    logic fabric_line_req_valid;
    logic l2_line_req_ready;

    logic [GLOBAL_TAG_W-1:0]
        fabric_line_req_global_tag;

    logic [LINE_ADDR_W-1:0]
        fabric_line_req_line_addr;


    logic l2_line_resp_valid;

    logic [GLOBAL_TAG_W-1:0]
        l2_line_resp_global_tag;

    logic [LINE_ADDR_W-1:0]
        l2_line_resp_line_addr;

    logic l2_line_resp_fault;

    logic [31:0]
        l2_line_resp_data
            [0:LINE_WORDS-1];


    logic l2_store_valid;

    logic [L2_STORE_LANES-1:0]
        l2_store_lane_mask;

    logic [31:0]
        l2_store_word_addr
            [0:L2_STORE_LANES-1];


    integer flatten_client;
    integer flatten_lane;
    integer flatten_index;


    initial begin
        if (CLIENT_COUNT < 1) begin
            $fatal(
                1,
                "RTL9D3 CLIENT_COUNT must be >= 1"
            );
        end

        if (LOCAL_TAG_W < 1) begin
            $fatal(
                1,
                "RTL9D3 LOCAL_TAG_W must be >= 1"
            );
        end

        if (STORE_LANES_PER_CLIENT < 1) begin
            $fatal(
                1,
                "RTL9D3 STORE_LANES_PER_CLIENT must be >= 1"
            );
        end

        if (LINE_WORDS < 1) begin
            $fatal(
                1,
                "RTL9D3 LINE_WORDS must be >= 1"
            );
        end

        if (
            (
                LINE_WORDS
                & (LINE_WORDS - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "RTL9D3 LINE_WORDS must be a power of two"
            );
        end

        if (
            CLIENT_ID_W
            != EXPECTED_CLIENT_ID_W
        ) begin
            $fatal(
                1,
                "RTL9D3 CLIENT_ID_W inconsistent with CLIENT_COUNT"
            );
        end

        if (
            GLOBAL_TAG_W
            != EXPECTED_GLOBAL_TAG_W
        ) begin
            $fatal(
                1,
                "RTL9D3 GLOBAL_TAG_W inconsistent"
            );
        end

        if (
            LINE_ADDR_W
            != EXPECTED_LINE_ADDR_W
        ) begin
            $fatal(
                1,
                "RTL9D3 LINE_ADDR_W inconsistent with LINE_WORDS"
            );
        end
    end


    /*
     * Flatten all active per-client physical store lanes.
     *
     * Data is intentionally absent: the shared L2 needs only conservative
     * line visibility information for invalidation/refill-kill decisions.
     */
    always_comb begin
        l2_store_valid = 1'b0;
        l2_store_lane_mask = '0;

        for (
            flatten_index = 0;
            flatten_index < L2_STORE_LANES;
            flatten_index = flatten_index + 1
        ) begin
            l2_store_word_addr[
                flatten_index
            ] = '0;
        end

        for (
            flatten_client = 0;
            flatten_client < CLIENT_COUNT;
            flatten_client = flatten_client + 1
        ) begin
            if (
                client_store_valid_i[
                    flatten_client
                ]
            ) begin
                l2_store_valid = 1'b1;
            end

            for (
                flatten_lane = 0;
                flatten_lane < STORE_LANES_PER_CLIENT;
                flatten_lane = flatten_lane + 1
            ) begin
                flatten_index =
                    (
                        flatten_client
                        * STORE_LANES_PER_CLIENT
                    )
                    + flatten_lane;

                l2_store_lane_mask[
                    flatten_index
                ] =
                    client_store_valid_i[
                        flatten_client
                    ]
                    && client_store_lane_mask_i[
                        flatten_client
                    ][
                        flatten_lane
                    ];

                l2_store_word_addr[
                    flatten_index
                ] =
                    client_store_word_addr_i[
                        flatten_client
                    ][
                        flatten_lane
                    ];
            end
        end
    end


    a0_line_request_fabric #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS),
        .CLIENT_ID_W(CLIENT_ID_W),
        .GLOBAL_TAG_W(GLOBAL_TAG_W)
    ) line_fabric (
        .clk(clk),
        .rst_n(rst_n),

        .client_req_valid_i(
            client_req_valid_i
        ),
        .client_req_ready_o(
            client_req_ready_o
        ),
        .client_req_local_tag_i(
            client_req_local_tag_i
        ),
        .client_req_line_addr_i(
            client_req_line_addr_i
        ),

        .line_req_valid_o(
            fabric_line_req_valid
        ),
        .line_req_ready_i(
            l2_line_req_ready
        ),
        .line_req_global_tag_o(
            fabric_line_req_global_tag
        ),
        .line_req_line_addr_o(
            fabric_line_req_line_addr
        ),

        .line_resp_valid_i(
            l2_line_resp_valid
        ),
        .line_resp_global_tag_i(
            l2_line_resp_global_tag
        ),
        .line_resp_line_addr_i(
            l2_line_resp_line_addr
        ),
        .line_resp_fault_i(
            l2_line_resp_fault
        ),
        .line_resp_data_i(
            l2_line_resp_data
        ),

        .client_resp_valid_o(
            client_resp_valid_o
        ),
        .client_resp_local_tag_o(
            client_resp_local_tag_o
        ),
        .client_resp_line_addr_o(
            client_resp_line_addr_o
        ),
        .client_resp_fault_o(
            client_resp_fault_o
        ),
        .client_resp_data_o(
            client_resp_data_o
        ),

        .line_resp_tag_error_o(
            line_resp_tag_error_o
        )
    );


    a0_l2_line_cache #(
        .STORE_LANES(L2_STORE_LANES),
        .LINE_WORDS(LINE_WORDS),
        .SET_COUNT(L2_SET_COUNT),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .MISS_COUNT(L2_MISS_COUNT)
    ) l2_line_cache (
        .clk(clk),
        .rst_n(rst_n),

        .line_req_valid_i(
            fabric_line_req_valid
        ),
        .line_req_ready_o(
            l2_line_req_ready
        ),
        .line_req_global_tag_i(
            fabric_line_req_global_tag
        ),
        .line_req_line_addr_i(
            fabric_line_req_line_addr
        ),

        .line_mem_req_valid_o(
            line_mem_req_valid_o
        ),
        .line_mem_req_ready_i(
            line_mem_req_ready_i
        ),
        .line_mem_req_global_tag_o(
            line_mem_req_global_tag_o
        ),
        .line_mem_req_line_addr_o(
            line_mem_req_line_addr_o
        ),

        .line_mem_resp_valid_i(
            line_mem_resp_valid_i
        ),
        .line_mem_resp_global_tag_i(
            line_mem_resp_global_tag_i
        ),
        .line_mem_resp_line_addr_i(
            line_mem_resp_line_addr_i
        ),
        .line_mem_resp_fault_i(
            line_mem_resp_fault_i
        ),
        .line_mem_resp_data_i(
            line_mem_resp_data_i
        ),

        .line_resp_valid_o(
            l2_line_resp_valid
        ),
        .line_resp_global_tag_o(
            l2_line_resp_global_tag
        ),
        .line_resp_line_addr_o(
            l2_line_resp_line_addr
        ),
        .line_resp_fault_o(
            l2_line_resp_fault
        ),
        .line_resp_data_o(
            l2_line_resp_data
        ),

        .store_valid_i(
            l2_store_valid
        ),
        .store_lane_mask_i(
            l2_store_lane_mask
        ),
        .store_word_addr_i(
            l2_store_word_addr
        )
    );

endmodule
