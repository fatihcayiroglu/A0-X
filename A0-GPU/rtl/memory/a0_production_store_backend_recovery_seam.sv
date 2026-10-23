`timescale 1ns/1ps

/* PROD-SEAM-P14 successor: frozen P13 seam semantics plus bounded write-status timeout. */
module a0_production_store_backend_recovery_seam #(
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
    input logic backend_write_reuse_safe_i,

    input logic backend_recovery_safe_valid_i,
    output logic backend_recovery_safe_ready_o,
    input logic arch_store_abort_ack_valid_i,
    input logic [WRITE_ID_W-1:0] arch_store_abort_ack_write_id_i,
    output logic arch_store_abort_ack_ready_o,
    output logic recovery_abort_req_valid_o,
    output logic [EXTERNAL_WRITE_ATTEMPT_ID_W-1:0] recovery_abort_req_attempt_id_o,
    output logic [WRITE_ID_W-1:0] recovery_abort_req_write_id_o,
    output logic [31:0] recovery_abort_req_word_addr_o,
    output logic [31:0] recovery_abort_req_wdata_o,
    output logic [LINE_ADDR_W-1:0] recovery_abort_req_line_addr_o,
    output logic [WRITE_RETRY_INDEX_W-1:0] recovery_abort_req_retry_count_o,
    output logic recovery_active_o,
    output logic recovery_complete_pulse_o,
    output logic recovery_protocol_error_o
);
    logic p14_rst_n;
    logic predecessor_reset_pulse;
    logic source_quiesced;
    logic [CUS_PER_CLUSTER-1:0] gated_store_valid [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] p14_store_ready [0:CLUSTER_COUNT-1];
    logic [L2_SLICE_COUNT-1:0] gated_line_req_valid;
    logic [L2_SLICE_COUNT-1:0] p14_line_req_ready;
    integer c;

    assign p14_rst_n = rst_n && !predecessor_reset_pulse;

    always_comb begin
        source_quiesced = 1'b1;
        for (c = 0; c < CLUSTER_COUNT; c = c + 1) begin
            source_quiesced = source_quiesced && !(|store_commit_valid_i[c]);
            gated_store_valid[c] = recovery_active_o ? '0 : store_commit_valid_i[c];
            store_commit_ready_o[c] = recovery_active_o ? '0 : p14_store_ready[c];
        end
        gated_line_req_valid = recovery_active_o ? '0 : line_mem_req_valid_i;
        line_mem_req_ready_o = recovery_active_o ? '0 : p14_line_req_ready;
    end

    a0_production_store_backend_timeout_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT), .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES), .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS), .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT), .READ_EPOCH_W(READ_EPOCH_W),
        .WRITE_ID_W(WRITE_ID_W), .MAX_WRITE_RETRIES(MAX_WRITE_RETRIES),
        .STATUS_TIMEOUT_CYCLES(STATUS_TIMEOUT_CYCLES),
        .STATUS_TIMEOUT_COUNT_W(STATUS_TIMEOUT_COUNT_W),
        .WRITE_RETRY_INDEX_W(WRITE_RETRY_INDEX_W)
    ) p14_seam (
        .rst_n(p14_rst_n),
        .store_commit_valid_i(gated_store_valid),
        .store_commit_ready_o(p14_store_ready),
        .line_mem_req_valid_i(gated_line_req_valid),
        .line_mem_req_ready_o(p14_line_req_ready),
        .*
    );

    a0_backend_write_failure_recovery_guard #(
        .WRITE_ID_W(WRITE_ID_W),
        .ATTEMPT_ID_W(EXTERNAL_WRITE_ATTEMPT_ID_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .RETRY_COUNT_W(WRITE_RETRY_INDEX_W),
        .READ_COUNT_W(READ_OCCUPANCY_W)
    ) recovery_guard (
        .clk(clk), .rst_n(rst_n),
        .failure_i(write_retry_exhausted_o || write_terminal_failure_o),
        .failed_attempt_id_i(backend_issue_write_attempt_id_o),
        .failed_word_addr_i(backend_issue_word_addr_o),
        .failed_wdata_i(backend_issue_wdata_o),
        .failed_line_addr_i(backend_issue_line_addr_o),
        .failed_retry_count_i(write_retry_count_o),
        .read_outstanding_i(read_outstanding_o),
        .epoch_outstanding_i(read_epoch_outstanding_o),
        .source_quiesced_i(source_quiesced),
        .backend_recovery_safe_valid_i(backend_recovery_safe_valid_i),
        .backend_recovery_safe_ready_o(backend_recovery_safe_ready_o),
        .arch_abort_ack_valid_i(arch_store_abort_ack_valid_i),
        .arch_abort_ack_write_id_i(arch_store_abort_ack_write_id_i),
        .arch_abort_ack_ready_o(arch_store_abort_ack_ready_o),
        .abort_req_valid_o(recovery_abort_req_valid_o),
        .abort_req_attempt_id_o(recovery_abort_req_attempt_id_o),
        .abort_req_write_id_o(recovery_abort_req_write_id_o),
        .abort_req_word_addr_o(recovery_abort_req_word_addr_o),
        .abort_req_wdata_o(recovery_abort_req_wdata_o),
        .abort_req_line_addr_o(recovery_abort_req_line_addr_o),
        .abort_req_retry_count_o(recovery_abort_req_retry_count_o),
        .recovery_active_o(recovery_active_o),
        .predecessor_reset_pulse_o(predecessor_reset_pulse),
        .recovery_complete_pulse_o(recovery_complete_pulse_o),
        .recovery_protocol_error_o(recovery_protocol_error_o)
    );
endmodule
