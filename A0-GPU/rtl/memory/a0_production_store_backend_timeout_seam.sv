`timescale 1ns/1ps

/* PROD-SEAM-P14 successor: frozen P13 seam semantics plus bounded write-status timeout. */
module a0_production_store_backend_timeout_seam #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer STORE_LANES = 32,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer NETWORK_TAG_W = 5,
    parameter integer READ_TRACK_COUNT = 8,
    parameter integer READ_EPOCH_W = 16,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WRITE_RETRIES = 2,
    parameter integer STATUS_TIMEOUT_CYCLES = 32,
    parameter integer STATUS_TIMEOUT_COUNT_W =
        (STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STATUS_TIMEOUT_CYCLES),
    parameter integer WRITE_RETRY_INDEX_W =
        (MAX_WRITE_RETRIES < 1) ? 1 : $clog2(MAX_WRITE_RETRIES + 1),

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer LINE_PORT_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT),
    parameter integer BASE_READ_TAG_W = LINE_PORT_ID_W + NETWORK_TAG_W,
    parameter integer EXTERNAL_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W,
    parameter integer EXTERNAL_WRITE_ATTEMPT_ID_W = WRITE_ID_W + WRITE_RETRY_INDEX_W,
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

    output logic backend_protocol_error_o,
    output logic read_duplicate_block_o,
    output logic [READ_OCCUPANCY_W-1:0] read_outstanding_o,
    output logic read_capacity_full_o,
    output logic read_epoch_wrap_block_o,
    output logic [READ_EPOCH_W-1:0] next_read_generation_o,
    output logic [READ_OCCUPANCY_W-1:0] read_epoch_outstanding_o,
    output logic write_ack_protocol_error_o,
    output logic write_wrap_block_o,
    output logic [WRITE_ID_W-1:0] next_write_id_o,
    output logic write_pending_o,
    output logic write_issued_o,
    output logic write_status_protocol_error_o,
    output logic write_retry_exhausted_o,
    output logic write_terminal_failure_o,
    output logic [WRITE_RETRY_INDEX_W-1:0] write_retry_count_o,
    output logic write_retry_pending_o,
    output logic write_status_timeout_pulse_o,
    output logic write_status_timeout_seen_o,
    output logic write_status_watchdog_live_o,
    output logic [STATUS_TIMEOUT_COUNT_W-1:0] write_status_watchdog_count_o,

    output logic backend_issue_valid_o,
    input logic backend_issue_ready_i,
    output logic backend_issue_write_o,
    output logic [EXTERNAL_READ_ID_W-1:0] backend_issue_read_id_o,
    output logic [EXTERNAL_WRITE_ATTEMPT_ID_W-1:0]
        backend_issue_write_attempt_id_o,
    output logic [31:0] backend_issue_word_addr_o,
    output logic [31:0] backend_issue_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_issue_line_addr_o,

    input logic backend_read_resp_valid_i,
    input logic [EXTERNAL_READ_ID_W-1:0] backend_read_resp_id_i,
    input logic [LINE_ADDR_W-1:0] backend_read_resp_line_addr_i,
    input logic backend_read_resp_fault_i,
    input logic [31:0] backend_read_resp_data_i [0:LINE_WORDS-1],
    input logic backend_read_epoch_reuse_safe_i,

    input logic backend_write_status_valid_i,
    input logic [EXTERNAL_WRITE_ATTEMPT_ID_W-1:0]
        backend_write_status_attempt_id_i,
    input logic backend_write_status_success_i,
    input logic backend_write_status_retryable_i,
    input logic backend_write_reuse_safe_i
);
    logic p13_status_valid;
    logic [EXTERNAL_WRITE_ATTEMPT_ID_W-1:0] p13_status_attempt_id;
    logic p13_status_success;
    logic p13_status_retryable;
    logic write_issue_fire;

    assign write_issue_fire = backend_issue_valid_o
        && backend_issue_ready_i && backend_issue_write_o;

    a0_backend_write_status_timeout_guard #(
        .ATTEMPT_ID_W(EXTERNAL_WRITE_ATTEMPT_ID_W),
        .STATUS_TIMEOUT_CYCLES(STATUS_TIMEOUT_CYCLES),
        .TIMEOUT_COUNT_W(STATUS_TIMEOUT_COUNT_W)
    ) status_timeout_guard (
        .clk(clk), .rst_n(rst_n),
        .write_issue_fire_i(write_issue_fire),
        .write_issue_attempt_id_i(backend_issue_write_attempt_id_o),
        .backend_status_valid_i(backend_write_status_valid_i),
        .backend_status_attempt_id_i(backend_write_status_attempt_id_i),
        .backend_status_success_i(backend_write_status_success_i),
        .backend_status_retryable_i(backend_write_status_retryable_i),
        .p13_status_valid_o(p13_status_valid),
        .p13_status_attempt_id_o(p13_status_attempt_id),
        .p13_status_success_o(p13_status_success),
        .p13_status_retryable_o(p13_status_retryable),
        .timeout_pulse_o(write_status_timeout_pulse_o),
        .timeout_seen_o(write_status_timeout_seen_o),
        .watchdog_live_o(write_status_watchdog_live_o),
        .watchdog_count_o(write_status_watchdog_count_o)
    );

    a0_production_store_backend_retry_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT),
        .READ_EPOCH_W(READ_EPOCH_W),
        .WRITE_ID_W(WRITE_ID_W),
        .MAX_WRITE_RETRIES(MAX_WRITE_RETRIES),
        .WRITE_RETRY_INDEX_W(WRITE_RETRY_INDEX_W)
    ) p13_seam (
        .backend_write_status_valid_i(p13_status_valid),
        .backend_write_status_attempt_id_i(p13_status_attempt_id),
        .backend_write_status_success_i(p13_status_success),
        .backend_write_status_retryable_i(p13_status_retryable),
        .*
    );
endmodule
