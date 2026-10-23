`timescale 1ns/1ps

/* PROD-SEAM-P11 successor: duplicate-word canonicalization before frozen P10. */
module a0_production_store_backend_collision_seam #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer STORE_LANES = 32,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer NETWORK_TAG_W = 5,
    parameter integer READ_TRACK_COUNT = 8,
    parameter integer READ_EPOCH_W = 16,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer LINE_PORT_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT),
    parameter integer BASE_READ_TAG_W = LINE_PORT_ID_W + NETWORK_TAG_W,
    parameter integer EXTERNAL_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W,
    parameter integer READ_OCCUPANCY_W =
        (READ_TRACK_COUNT <= 1) ? 1 : $clog2(READ_TRACK_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic [CUS_PER_CLUSTER-1:0]
        store_commit_valid_i [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        store_commit_ready_o [0:CLUSTER_COUNT-1],
    input logic [STORE_LANES-1:0]
        store_commit_lane_mask_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [31:0]
        store_commit_word_addr_i
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],
    input logic [31:0]
        store_commit_wdata_i
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],
    output logic [CUS_PER_CLUSTER-1:0]
        store_duplicate_collapse_o [0:CLUSTER_COUNT-1],

    input logic [L2_SLICE_COUNT-1:0] line_mem_req_valid_i,
    output logic [L2_SLICE_COUNT-1:0] line_mem_req_ready_o,
    input logic [NETWORK_TAG_W-1:0]
        line_mem_req_network_tag_i [0:L2_SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_i [0:L2_SLICE_COUNT-1],

    output logic [L2_SLICE_COUNT-1:0] line_mem_resp_valid_o,
    output logic [NETWORK_TAG_W-1:0]
        line_mem_resp_network_tag_o [0:L2_SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_o [0:L2_SLICE_COUNT-1],
    output logic line_mem_resp_fault_o [0:L2_SLICE_COUNT-1],
    output logic [31:0]
        line_mem_resp_data_o [0:L2_SLICE_COUNT-1][0:LINE_WORDS-1],

    output logic backend_resp_protocol_error_o,
    output logic read_duplicate_block_o,
    output logic [READ_OCCUPANCY_W-1:0] read_outstanding_o,
    output logic read_capacity_full_o,
    output logic epoch_wrap_block_o,
    output logic [READ_EPOCH_W-1:0] next_generation_o,
    output logic [READ_OCCUPANCY_W-1:0] epoch_outstanding_o,

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [EXTERNAL_READ_ID_W-1:0] backend_cmd_read_id_o,
    output logic [31:0] backend_cmd_word_addr_o,
    output logic [31:0] backend_cmd_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,

    input logic backend_resp_valid_i,
    input logic [EXTERNAL_READ_ID_W-1:0] backend_resp_read_id_i,
    input logic [LINE_ADDR_W-1:0] backend_resp_line_addr_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_data_i [0:LINE_WORDS-1],
    input logic backend_epoch_reuse_safe_i
);
    logic [STORE_LANES-1:0]
        canonical_lane_mask [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0]
        canonical_word_addr
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];
    logic [31:0]
        canonical_wdata
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];

    a0_store_commit_duplicate_canonicalizer #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES)
    ) duplicate_canonicalizer (
        .commit_valid_i(store_commit_valid_i),
        .commit_lane_mask_i(store_commit_lane_mask_i),
        .commit_word_addr_i(store_commit_word_addr_i),
        .commit_wdata_i(store_commit_wdata_i),
        .canonical_lane_mask_o(canonical_lane_mask),
        .canonical_word_addr_o(canonical_word_addr),
        .canonical_wdata_o(canonical_wdata),
        .duplicate_collapse_o(store_duplicate_collapse_o)
    );

    a0_production_store_backend_epoch_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT),
        .READ_EPOCH_W(READ_EPOCH_W)
    ) p10_seam (
        .clk(clk), .rst_n(rst_n),
        .store_commit_valid_i(store_commit_valid_i),
        .store_commit_ready_o(store_commit_ready_o),
        .store_commit_lane_mask_i(canonical_lane_mask),
        .store_commit_word_addr_i(canonical_word_addr),
        .store_commit_wdata_i(canonical_wdata),
        .line_mem_req_valid_i(line_mem_req_valid_i),
        .line_mem_req_ready_o(line_mem_req_ready_o),
        .line_mem_req_network_tag_i(line_mem_req_network_tag_i),
        .line_mem_req_line_addr_i(line_mem_req_line_addr_i),
        .line_mem_resp_valid_o(line_mem_resp_valid_o),
        .line_mem_resp_network_tag_o(line_mem_resp_network_tag_o),
        .line_mem_resp_line_addr_o(line_mem_resp_line_addr_o),
        .line_mem_resp_fault_o(line_mem_resp_fault_o),
        .line_mem_resp_data_o(line_mem_resp_data_o),
        .backend_resp_protocol_error_o(backend_resp_protocol_error_o),
        .read_duplicate_block_o(read_duplicate_block_o),
        .read_outstanding_o(read_outstanding_o),
        .read_capacity_full_o(read_capacity_full_o),
        .epoch_wrap_block_o(epoch_wrap_block_o),
        .next_generation_o(next_generation_o),
        .epoch_outstanding_o(epoch_outstanding_o),
        .backend_cmd_valid_o(backend_cmd_valid_o),
        .backend_cmd_ready_i(backend_cmd_ready_i),
        .backend_cmd_write_o(backend_cmd_write_o),
        .backend_cmd_read_id_o(backend_cmd_read_id_o),
        .backend_cmd_word_addr_o(backend_cmd_word_addr_o),
        .backend_cmd_wdata_o(backend_cmd_wdata_o),
        .backend_cmd_line_addr_o(backend_cmd_line_addr_o),
        .backend_resp_valid_i(backend_resp_valid_i),
        .backend_resp_read_id_i(backend_resp_read_id_i),
        .backend_resp_line_addr_i(backend_resp_line_addr_i),
        .backend_resp_fault_i(backend_resp_fault_i),
        .backend_resp_data_i(backend_resp_data_i),
        .backend_epoch_reuse_safe_i(backend_epoch_reuse_safe_i)
    );
endmodule
