`timescale 1ns/1ps

/*
 * PROD-SEAM-P0 migration-equivalence harness.
 *
 * The candidate seam plus the unchanged L2 is driven in lockstep with the
 * frozen a0_shared_l2_subsystem reference.  Public outputs are compared after
 * every active clock edge.  The hash-locked RTL9D-3 scenario suite also probes
 * the named candidate seam signals below while exercising the same behavioral
 * sequence used to close the reference composition.
 *
 * Hierarchical reference signals are deliberately confined to this one-time
 * migration proof.  They are not a production interface.
 */
module a0_production_cluster_line_seam_equivalence #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer STORE_LANES_PER_CLIENT = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer L2_SET_COUNT = 256,
    parameter integer L2_MISS_COUNT = 16,

    parameter integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),

    parameter integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W
) (
    input logic clk,
    input logic rst_n,

    input logic [CLIENT_COUNT-1:0] client_req_valid_i,
    output logic [CLIENT_COUNT-1:0] client_req_ready_o,
    input logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i [0:CLIENT_COUNT-1],
    input logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i [0:CLIENT_COUNT-1],

    output logic [CLIENT_COUNT-1:0] client_resp_valid_o,
    output logic [LOCAL_TAG_W-1:0]
        client_resp_local_tag_o [0:CLIENT_COUNT-1],
    output logic [LINE_ADDR_W-1:0]
        client_resp_line_addr_o [0:CLIENT_COUNT-1],
    output logic client_resp_fault_o [0:CLIENT_COUNT-1],
    output logic [31:0]
        client_resp_data_o [0:CLIENT_COUNT-1][0:LINE_WORDS-1],

    input logic [CLIENT_COUNT-1:0] client_store_valid_i,
    input logic [STORE_LANES_PER_CLIENT-1:0]
        client_store_lane_mask_i [0:CLIENT_COUNT-1],
    input logic [31:0]
        client_store_word_addr_i
            [0:CLIENT_COUNT-1][0:STORE_LANES_PER_CLIENT-1],

    output logic line_mem_req_valid_o,
    input logic line_mem_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o,
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o,

    input logic line_mem_resp_valid_i,
    input logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i,
    input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i,
    input logic line_mem_resp_fault_i,
    input logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1],

    output logic line_resp_tag_error_o
);

    localparam integer L2_STORE_LANES =
        CLIENT_COUNT * STORE_LANES_PER_CLIENT;

    logic fabric_line_req_valid;
    logic l2_line_req_ready;
    logic [GLOBAL_TAG_W-1:0] fabric_line_req_global_tag;
    logic [LINE_ADDR_W-1:0] fabric_line_req_line_addr;

    logic l2_line_resp_valid;
    logic [GLOBAL_TAG_W-1:0] l2_line_resp_global_tag;
    logic [LINE_ADDR_W-1:0] l2_line_resp_line_addr;
    logic l2_line_resp_fault;
    logic [31:0] l2_line_resp_data [0:LINE_WORDS-1];

    logic l2_store_valid;
    logic [L2_STORE_LANES-1:0] l2_store_lane_mask;
    logic [31:0] l2_store_word_addr [0:L2_STORE_LANES-1];

    logic [CLIENT_COUNT-1:0] reference_client_req_ready;
    logic [CLIENT_COUNT-1:0] reference_client_resp_valid;
    logic [LOCAL_TAG_W-1:0]
        reference_client_resp_local_tag [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        reference_client_resp_line_addr [0:CLIENT_COUNT-1];
    logic reference_client_resp_fault [0:CLIENT_COUNT-1];
    logic [31:0]
        reference_client_resp_data [0:CLIENT_COUNT-1][0:LINE_WORDS-1];
    logic reference_line_mem_req_valid;
    logic [GLOBAL_TAG_W-1:0] reference_line_mem_req_global_tag;
    logic [LINE_ADDR_W-1:0] reference_line_mem_req_line_addr;
    logic reference_line_resp_tag_error;

    integer compare_client;
    integer compare_word;

    a0_production_cluster_line_seam #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .STORE_LANES_PER_CLIENT(STORE_LANES_PER_CLIENT),
        .LINE_WORDS(LINE_WORDS),
        .CLIENT_ID_W(CLIENT_ID_W),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) candidate_seam (
        .clk(clk),
        .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .client_store_valid_i(client_store_valid_i),
        .client_store_lane_mask_i(client_store_lane_mask_i),
        .client_store_word_addr_i(client_store_word_addr_i),
        .line_req_valid_o(fabric_line_req_valid),
        .line_req_ready_i(l2_line_req_ready),
        .line_req_global_tag_o(fabric_line_req_global_tag),
        .line_req_line_addr_o(fabric_line_req_line_addr),
        .line_resp_valid_i(l2_line_resp_valid),
        .line_resp_global_tag_i(l2_line_resp_global_tag),
        .line_resp_line_addr_i(l2_line_resp_line_addr),
        .line_resp_fault_i(l2_line_resp_fault),
        .line_resp_data_i(l2_line_resp_data),
        .line_resp_tag_error_o(line_resp_tag_error_o),
        .store_observe_valid_o(l2_store_valid),
        .store_observe_lane_mask_o(l2_store_lane_mask),
        .store_observe_word_addr_o(l2_store_word_addr)
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
        .line_req_valid_i(fabric_line_req_valid),
        .line_req_ready_o(l2_line_req_ready),
        .line_req_global_tag_i(fabric_line_req_global_tag),
        .line_req_line_addr_i(fabric_line_req_line_addr),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_global_tag_o(line_mem_req_global_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_global_tag_i(line_mem_resp_global_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i),
        .line_resp_valid_o(l2_line_resp_valid),
        .line_resp_global_tag_o(l2_line_resp_global_tag),
        .line_resp_line_addr_o(l2_line_resp_line_addr),
        .line_resp_fault_o(l2_line_resp_fault),
        .line_resp_data_o(l2_line_resp_data),
        .store_valid_i(l2_store_valid),
        .store_lane_mask_i(l2_store_lane_mask),
        .store_word_addr_i(l2_store_word_addr)
    );

    a0_shared_l2_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .STORE_LANES_PER_CLIENT(STORE_LANES_PER_CLIENT),
        .LINE_WORDS(LINE_WORDS),
        .L2_SET_COUNT(L2_SET_COUNT),
        .L2_MISS_COUNT(L2_MISS_COUNT),
        .CLIENT_ID_W(CLIENT_ID_W),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) reference_subsystem (
        .clk(clk),
        .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(reference_client_req_ready),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(reference_client_resp_valid),
        .client_resp_local_tag_o(reference_client_resp_local_tag),
        .client_resp_line_addr_o(reference_client_resp_line_addr),
        .client_resp_fault_o(reference_client_resp_fault),
        .client_resp_data_o(reference_client_resp_data),
        .client_store_valid_i(client_store_valid_i),
        .client_store_lane_mask_i(client_store_lane_mask_i),
        .client_store_word_addr_i(client_store_word_addr_i),
        .line_mem_req_valid_o(reference_line_mem_req_valid),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_global_tag_o(reference_line_mem_req_global_tag),
        .line_mem_req_line_addr_o(reference_line_mem_req_line_addr),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_global_tag_i(line_mem_resp_global_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i),
        .line_resp_tag_error_o(reference_line_resp_tag_error)
    );

    task automatic require_equivalent_outputs;
        begin
            if (client_req_ready_o !== reference_client_req_ready) begin
                $fatal(1, "PROD_SEAM_P0 client request-ready mismatch");
            end
            if (client_resp_valid_o !== reference_client_resp_valid) begin
                $fatal(1, "PROD_SEAM_P0 client response-valid mismatch");
            end
            if (line_mem_req_valid_o !== reference_line_mem_req_valid) begin
                $fatal(1, "PROD_SEAM_P0 backend request-valid mismatch");
            end
            if (
                line_mem_req_global_tag_o
                !== reference_line_mem_req_global_tag
            ) begin
                $fatal(1, "PROD_SEAM_P0 backend request-tag mismatch");
            end
            if (
                line_mem_req_line_addr_o
                !== reference_line_mem_req_line_addr
            ) begin
                $fatal(1, "PROD_SEAM_P0 backend request-address mismatch");
            end
            if (line_resp_tag_error_o !== reference_line_resp_tag_error) begin
                $fatal(1, "PROD_SEAM_P0 response-tag-error mismatch");
            end

            if (
                fabric_line_req_valid
                !== reference_subsystem.fabric_line_req_valid
            ) begin
                $fatal(1, "PROD_SEAM_P0 extracted request-valid mismatch");
            end
            if (
                fabric_line_req_global_tag
                !== reference_subsystem.fabric_line_req_global_tag
            ) begin
                $fatal(1, "PROD_SEAM_P0 extracted request-tag mismatch");
            end
            if (
                fabric_line_req_line_addr
                !== reference_subsystem.fabric_line_req_line_addr
            ) begin
                $fatal(1, "PROD_SEAM_P0 extracted request-address mismatch");
            end
            if (l2_store_valid !== reference_subsystem.l2_store_valid) begin
                $fatal(1, "PROD_SEAM_P0 store-valid flatten mismatch");
            end
            if (
                l2_store_lane_mask
                !== reference_subsystem.l2_store_lane_mask
            ) begin
                $fatal(1, "PROD_SEAM_P0 store-mask flatten mismatch");
            end

            for (
                compare_client = 0;
                compare_client < CLIENT_COUNT;
                compare_client = compare_client + 1
            ) begin
                if (
                    client_resp_local_tag_o[compare_client]
                    !== reference_client_resp_local_tag[compare_client]
                ) begin
                    $fatal(1, "PROD_SEAM_P0 client response-tag mismatch");
                end
                if (
                    client_resp_line_addr_o[compare_client]
                    !== reference_client_resp_line_addr[compare_client]
                ) begin
                    $fatal(
                        1,
                        "PROD_SEAM_P0 client response-address mismatch"
                    );
                end
                if (
                    client_resp_fault_o[compare_client]
                    !== reference_client_resp_fault[compare_client]
                ) begin
                    $fatal(1, "PROD_SEAM_P0 client response-fault mismatch");
                end
                for (
                    compare_word = 0;
                    compare_word < LINE_WORDS;
                    compare_word = compare_word + 1
                ) begin
                    if (
                        client_resp_data_o[compare_client][compare_word]
                        !== reference_client_resp_data[
                            compare_client
                        ][compare_word]
                    ) begin
                        $fatal(1, "PROD_SEAM_P0 client response-data mismatch");
                    end
                end
            end

            for (
                compare_word = 0;
                compare_word < L2_STORE_LANES;
                compare_word = compare_word + 1
            ) begin
                if (
                    l2_store_word_addr[compare_word]
                    !== reference_subsystem.l2_store_word_addr[compare_word]
                ) begin
                    $fatal(1, "PROD_SEAM_P0 store-address flatten mismatch");
                end
            end
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            require_equivalent_outputs();
        end
    end

endmodule
