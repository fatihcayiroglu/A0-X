`timescale 1ns/1ps

/* PROD-SEAM-P10 successor: frozen P9 seam plus backend read incarnation guard. */
module a0_production_store_backend_epoch_seam #(
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
    logic p9_protocol_error;
    logic p10_protocol_error;

    logic p9_cmd_valid;
    logic p9_cmd_ready;
    logic p9_cmd_write;
    logic [BASE_READ_TAG_W-1:0] p9_cmd_read_tag;
    logic [31:0] p9_cmd_word_addr;
    logic [31:0] p9_cmd_wdata;
    logic [LINE_ADDR_W-1:0] p9_cmd_line_addr;

    logic p9_resp_valid;
    logic [BASE_READ_TAG_W-1:0] p9_resp_read_tag;
    logic [LINE_ADDR_W-1:0] p9_resp_line_addr;
    logic p9_resp_fault;
    logic [31:0] p9_resp_data [0:LINE_WORDS-1];

    assign backend_resp_protocol_error_o = p9_protocol_error || p10_protocol_error;

    a0_production_store_backend_transaction_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT)
    ) p9_seam (
        .clk(clk), .rst_n(rst_n),
        .store_commit_valid_i(store_commit_valid_i),
        .store_commit_ready_o(store_commit_ready_o),
        .store_commit_lane_mask_i(store_commit_lane_mask_i),
        .store_commit_word_addr_i(store_commit_word_addr_i),
        .store_commit_wdata_i(store_commit_wdata_i),
        .line_mem_req_valid_i(line_mem_req_valid_i),
        .line_mem_req_ready_o(line_mem_req_ready_o),
        .line_mem_req_network_tag_i(line_mem_req_network_tag_i),
        .line_mem_req_line_addr_i(line_mem_req_line_addr_i),
        .line_mem_resp_valid_o(line_mem_resp_valid_o),
        .line_mem_resp_network_tag_o(line_mem_resp_network_tag_o),
        .line_mem_resp_line_addr_o(line_mem_resp_line_addr_o),
        .line_mem_resp_fault_o(line_mem_resp_fault_o),
        .line_mem_resp_data_o(line_mem_resp_data_o),
        .backend_resp_protocol_error_o(p9_protocol_error),
        .read_duplicate_block_o(read_duplicate_block_o),
        .read_outstanding_o(read_outstanding_o),
        .read_capacity_full_o(read_capacity_full_o),
        .backend_cmd_valid_o(p9_cmd_valid),
        .backend_cmd_ready_i(p9_cmd_ready),
        .backend_cmd_write_o(p9_cmd_write),
        .backend_cmd_read_tag_o(p9_cmd_read_tag),
        .backend_cmd_word_addr_o(p9_cmd_word_addr),
        .backend_cmd_wdata_o(p9_cmd_wdata),
        .backend_cmd_line_addr_o(p9_cmd_line_addr),
        .backend_resp_valid_i(p9_resp_valid),
        .backend_resp_read_tag_i(p9_resp_read_tag),
        .backend_resp_line_addr_i(p9_resp_line_addr),
        .backend_resp_fault_i(p9_resp_fault),
        .backend_resp_data_i(p9_resp_data)
    );

    a0_backend_read_epoch_guard #(
        .BASE_READ_TAG_W(BASE_READ_TAG_W),
        .READ_EPOCH_W(READ_EPOCH_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS),
        .READ_TRACK_COUNT(READ_TRACK_COUNT)
    ) epoch_guard (
        .clk(clk), .rst_n(rst_n),
        .upstream_cmd_valid_i(p9_cmd_valid),
        .upstream_cmd_ready_o(p9_cmd_ready),
        .upstream_cmd_write_i(p9_cmd_write),
        .upstream_cmd_read_tag_i(p9_cmd_read_tag),
        .upstream_cmd_word_addr_i(p9_cmd_word_addr),
        .upstream_cmd_wdata_i(p9_cmd_wdata),
        .upstream_cmd_line_addr_i(p9_cmd_line_addr),
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
        .upstream_resp_valid_o(p9_resp_valid),
        .upstream_resp_read_tag_o(p9_resp_read_tag),
        .upstream_resp_line_addr_o(p9_resp_line_addr),
        .upstream_resp_fault_o(p9_resp_fault),
        .upstream_resp_data_o(p9_resp_data),
        .backend_epoch_reuse_safe_i(backend_epoch_reuse_safe_i),
        .epoch_protocol_error_o(p10_protocol_error),
        .epoch_wrap_block_o(epoch_wrap_block_o),
        .next_generation_o(next_generation_o),
        .epoch_outstanding_o(epoch_outstanding_o)
    );
endmodule
