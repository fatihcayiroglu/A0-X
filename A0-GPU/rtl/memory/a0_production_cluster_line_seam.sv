`timescale 1ns/1ps

/*
 * A0 PROD-SEAM-P0 production cluster line seam.
 *
 * This L2-free adapter extracts the requester-tagged line fabric and the
 * physical-store observation flattening that were previously hidden inside
 * a0_shared_l2_subsystem.  It preserves the existing cluster-local contract:
 *
 *   - one requester-tagged client port per CU
 *   - one post-local-fabric ready/valid request stream
 *   - global request tag layout {client_id, local_tag}
 *   - one no-backpressure response stream, demultiplexed by requester tag
 *   - one conservative flattened physical-store observation vector
 *
 * No L2 storage, NoC transport, coherence, memory-controller policy, core,
 * L1, MSHR, or store-ordering policy is implemented here.
 */
module a0_production_cluster_line_seam #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer STORE_LANES_PER_CLIENT = 32,
    parameter integer LINE_WORDS = 8,

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

    /* Per-client requester-tagged line interface. */
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

    /* Per-client physical-store visibility from the cluster controller. */
    input logic [CLIENT_COUNT-1:0]
        client_store_valid_i,

    input logic [STORE_LANES_PER_CLIENT-1:0]
        client_store_lane_mask_i
            [0:CLIENT_COUNT-1],

    input logic [31:0]
        client_store_word_addr_i
            [0:CLIENT_COUNT-1]
            [0:STORE_LANES_PER_CLIENT-1],

    /* L2-free post-local-fabric request seam. */
    output logic line_req_valid_o,
    input logic line_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        line_req_global_tag_o,

    output logic [LINE_ADDR_W-1:0]
        line_req_line_addr_o,

    /* L2-free post-local-fabric response seam. */
    input logic line_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        line_resp_global_tag_i,

    input logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_i,

    input logic line_resp_fault_i,

    input logic [31:0]
        line_resp_data_i
            [0:LINE_WORDS-1],

    output logic line_resp_tag_error_o,

    /* Flattened physical-store visibility for the downstream cache domain. */
    output logic store_observe_valid_o,

    output logic [
        (CLIENT_COUNT * STORE_LANES_PER_CLIENT)-1:0
    ] store_observe_lane_mask_o,

    output logic [31:0]
        store_observe_word_addr_o
            [0:(CLIENT_COUNT * STORE_LANES_PER_CLIENT)-1]
);

    localparam integer STORE_LANE_COUNT =
        CLIENT_COUNT * STORE_LANES_PER_CLIENT;

    localparam integer EXPECTED_CLIENT_ID_W =
        (CLIENT_COUNT <= 1)
            ? 1
            : $clog2(CLIENT_COUNT);

    localparam integer EXPECTED_GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W;

    localparam integer EXPECTED_WORD_SELECT_W =
        (LINE_WORDS <= 1)
            ? 0
            : $clog2(LINE_WORDS);

    localparam integer EXPECTED_LINE_ADDR_W =
        32 - EXPECTED_WORD_SELECT_W;

    integer flatten_client;
    integer flatten_lane;

    initial begin
        if (CLIENT_COUNT < 1) begin
            $fatal(1, "PROD_SEAM_P0 CLIENT_COUNT must be >= 1");
        end
        if (LOCAL_TAG_W < 1) begin
            $fatal(1, "PROD_SEAM_P0 LOCAL_TAG_W must be >= 1");
        end
        if (STORE_LANES_PER_CLIENT < 1) begin
            $fatal(
                1,
                "PROD_SEAM_P0 STORE_LANES_PER_CLIENT must be >= 1"
            );
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "PROD_SEAM_P0 LINE_WORDS must be >= 1");
        end
        if ((LINE_WORDS & (LINE_WORDS - 1)) != 0) begin
            $fatal(
                1,
                "PROD_SEAM_P0 LINE_WORDS must be a power of two"
            );
        end
        if (CLIENT_ID_W != EXPECTED_CLIENT_ID_W) begin
            $fatal(
                1,
                "PROD_SEAM_P0 CLIENT_ID_W inconsistent with CLIENT_COUNT"
            );
        end
        if (GLOBAL_TAG_W != EXPECTED_GLOBAL_TAG_W) begin
            $fatal(1, "PROD_SEAM_P0 GLOBAL_TAG_W inconsistent");
        end
        if (WORD_SELECT_W != EXPECTED_WORD_SELECT_W) begin
            $fatal(1, "PROD_SEAM_P0 WORD_SELECT_W inconsistent");
        end
        if (LINE_ADDR_W != EXPECTED_LINE_ADDR_W) begin
            $fatal(1, "PROD_SEAM_P0 LINE_ADDR_W inconsistent");
        end
        if (STORE_LANE_COUNT < 1) begin
            $fatal(1, "PROD_SEAM_P0 STORE_LANE_COUNT must be >= 1");
        end
    end

    /*
     * Preserve the closed shared-L2 wrapper's flattening semantics exactly:
     * a client's valid gates all of its lane-mask bits, while every word
     * address is copied regardless of validity.  The downstream consumer must
     * use the valid and mask fields to qualify addresses.
     */
    always_comb begin
        store_observe_valid_o = 1'b0;
        store_observe_lane_mask_o = '0;

        for (
            flatten_client = 0;
            flatten_client < CLIENT_COUNT;
            flatten_client = flatten_client + 1
        ) begin
            if (client_store_valid_i[flatten_client]) begin
                store_observe_valid_o = 1'b1;
            end

            for (
                flatten_lane = 0;
                flatten_lane < STORE_LANES_PER_CLIENT;
                flatten_lane = flatten_lane + 1
            ) begin
                store_observe_lane_mask_o[
                    (flatten_client * STORE_LANES_PER_CLIENT)
                    + flatten_lane
                ] =
                    client_store_valid_i[flatten_client]
                    && client_store_lane_mask_i[
                        flatten_client
                    ][flatten_lane];

                store_observe_word_addr_o[
                    (flatten_client * STORE_LANES_PER_CLIENT)
                    + flatten_lane
                ] = client_store_word_addr_i[
                    flatten_client
                ][flatten_lane];
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
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),
        .line_req_valid_o(line_req_valid_o),
        .line_req_ready_i(line_req_ready_i),
        .line_req_global_tag_o(line_req_global_tag_o),
        .line_req_line_addr_o(line_req_line_addr_o),
        .line_resp_valid_i(line_resp_valid_i),
        .line_resp_global_tag_i(line_resp_global_tag_i),
        .line_resp_line_addr_i(line_resp_line_addr_i),
        .line_resp_fault_i(line_resp_fault_i),
        .line_resp_data_i(line_resp_data_i),
        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .line_resp_tag_error_o(line_resp_tag_error_o)
    );

endmodule
