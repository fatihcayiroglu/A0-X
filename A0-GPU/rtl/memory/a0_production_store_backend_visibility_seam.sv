`timescale 1ns/1ps

/*
 * PROD-SEAM-P8 production-shape composition for the unified visibility seam.
 *
 * This module converts the P7 per-{cluster,CU} visibility-commit shape and the
 * sliced-L2 refill shape into the flat ports of
 * a0_store_commit_line_backend_adapter.  It intentionally does not implement
 * dirty state, ownership, writeback, snoops, atomics, or a VRAM controller.
 */
module a0_production_store_backend_visibility_seam #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer STORE_LANES = 32,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer NETWORK_TAG_W = 5,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer LINE_PORT_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT),
    parameter integer BACKEND_READ_TAG_W =
        LINE_PORT_ID_W + NETWORK_TAG_W
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

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [31:0] backend_cmd_word_addr_o,
    output logic [31:0] backend_cmd_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,

    input logic backend_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_resp_read_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_resp_line_addr_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_data_i [0:LINE_WORDS-1]
);
    localparam integer COMMIT_PORT_COUNT = CLUSTER_COUNT * CUS_PER_CLUSTER;

    logic [COMMIT_PORT_COUNT-1:0] commit_valid_flat;
    logic [COMMIT_PORT_COUNT-1:0] commit_ready_flat;
    logic [STORE_LANES-1:0]
        commit_lane_mask_flat [0:COMMIT_PORT_COUNT-1];
    logic [31:0]
        commit_word_addr_flat [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic [31:0]
        commit_wdata_flat [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];

    always_comb begin
        commit_valid_flat = '0;
        for (integer cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
            store_commit_ready_o[cluster] = '0;
            for (integer cu = 0; cu < CUS_PER_CLUSTER; cu = cu + 1) begin
                commit_valid_flat[(cluster * CUS_PER_CLUSTER) + cu] =
                    store_commit_valid_i[cluster][cu];
                store_commit_ready_o[cluster][cu] =
                    commit_ready_flat[(cluster * CUS_PER_CLUSTER) + cu];
                commit_lane_mask_flat[(cluster * CUS_PER_CLUSTER) + cu] =
                    store_commit_lane_mask_i[cluster][cu];
                for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                    commit_word_addr_flat[(cluster * CUS_PER_CLUSTER) + cu][lane] =
                        store_commit_word_addr_i[cluster][cu][lane];
                    commit_wdata_flat[(cluster * CUS_PER_CLUSTER) + cu][lane] =
                        store_commit_wdata_i[cluster][cu][lane];
                end
            end
        end
    end

    a0_store_commit_line_backend_adapter #(
        .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),
        .STORE_LANES(STORE_LANES),
        .LINE_PORT_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W)
    ) backend_adapter (
        .clk(clk),
        .rst_n(rst_n),
        .commit_valid_i(commit_valid_flat),
        .commit_ready_o(commit_ready_flat),
        .commit_lane_mask_i(commit_lane_mask_flat),
        .commit_word_addr_i(commit_word_addr_flat),
        .commit_wdata_i(commit_wdata_flat),
        .line_req_valid_i(line_mem_req_valid_i),
        .line_req_ready_o(line_mem_req_ready_o),
        .line_req_network_tag_i(line_mem_req_network_tag_i),
        .line_req_line_addr_i(line_mem_req_line_addr_i),
        .line_resp_valid_o(line_mem_resp_valid_o),
        .line_resp_network_tag_o(line_mem_resp_network_tag_o),
        .line_resp_line_addr_o(line_mem_resp_line_addr_o),
        .line_resp_fault_o(line_mem_resp_fault_o),
        .line_resp_data_o(line_mem_resp_data_o),
        .backend_resp_protocol_error_o(backend_resp_protocol_error_o),
        .backend_cmd_valid_o(backend_cmd_valid_o),
        .backend_cmd_ready_i(backend_cmd_ready_i),
        .backend_cmd_write_o(backend_cmd_write_o),
        .backend_cmd_read_tag_o(backend_cmd_read_tag_o),
        .backend_cmd_word_addr_o(backend_cmd_word_addr_o),
        .backend_cmd_wdata_o(backend_cmd_wdata_o),
        .backend_cmd_line_addr_o(backend_cmd_line_addr_o),
        .backend_resp_valid_i(backend_resp_valid_i),
        .backend_resp_read_tag_i(backend_resp_read_tag_i),
        .backend_resp_line_addr_i(backend_resp_line_addr_i),
        .backend_resp_fault_i(backend_resp_fault_i),
        .backend_resp_data_i(backend_resp_data_i)
    );
endmodule
