`timescale 1ns/1ps

/* PROD-SEAM-P26: frozen P25 plus explicit STORE_WORD completion/retry guard. */
module a0_production_store_commit_completed_miss_visibility_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT_PER_SLICE = 64,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
    parameter integer STORE_WRITE_ID_W = 8,
    parameter integer MAX_STORE_RETRIES = 2,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer CLIENT_ID_W = (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),
    parameter integer GLOBAL_TAG_W = CLIENT_ID_W + LOCAL_TAG_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer SLICE_HASH_SHIFT = (SET_COUNT_PER_SLICE <= 1) ? 0 : $clog2(SET_COUNT_PER_SLICE),
    parameter integer RETRY_W = (MAX_WB_RETRIES < 1) ? 1 : $clog2(MAX_WB_RETRIES + 1),
    parameter integer LOCAL_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W,
    parameter integer BACKEND_ATTEMPT_ID_W = SLICE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer BACKEND_READ_TAG_W = SLICE_ID_W + GLOBAL_TAG_W,
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1),
    parameter integer STORE_RETRY_W = (MAX_STORE_RETRIES < 1) ? 1 : $clog2(MAX_STORE_RETRIES + 1),
    parameter integer STORE_ATTEMPT_ID_W = STORE_WRITE_ID_W + STORE_RETRY_W
) (
    input logic clk,
    input logic rst_n,

    input logic [CLIENT_COUNT-1:0] client_req_valid_i,
    output logic [CLIENT_COUNT-1:0] client_req_ready_o,
    input logic [LOCAL_TAG_W-1:0] client_req_local_tag_i [0:CLIENT_COUNT-1],
    input logic [LINE_ADDR_W-1:0] client_req_line_addr_i [0:CLIENT_COUNT-1],
    output logic [CLIENT_COUNT-1:0] client_resp_valid_o,
    output logic [LOCAL_TAG_W-1:0] client_resp_local_tag_o [0:CLIENT_COUNT-1],
    output logic [LINE_ADDR_W-1:0] client_resp_line_addr_o [0:CLIENT_COUNT-1],
    output logic client_resp_fault_o [0:CLIENT_COUNT-1],
    output logic [31:0] client_resp_data_o [0:CLIENT_COUNT-1][0:LINE_WORDS-1],

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    output logic [COMMIT_PORT_COUNT-1:0] commit_ready_o,
    input logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic [1:0] backend_cmd_kind_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_cmd_wb_attempt_id_o,
    output logic [STORE_ATTEMPT_ID_W-1:0] backend_cmd_store_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,
    output logic [31:0] backend_cmd_data_o [0:LINE_WORDS-1],
    output logic [31:0] backend_cmd_store_word_addr_o,
    output logic [31:0] backend_cmd_store_wdata_o,

    input logic backend_read_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_read_resp_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_read_resp_line_addr_i,
    input logic backend_read_resp_fault_i,
    input logic [31:0] backend_read_resp_data_i [0:LINE_WORDS-1],
    input logic backend_wb_status_valid_i,
    input logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,
    input logic backend_store_status_valid_i,
    input logic [STORE_ATTEMPT_ID_W-1:0] backend_store_status_attempt_id_i,
    input logic backend_store_status_success_i,
    input logic backend_store_status_retryable_i,
    input logic [SLICE_COUNT-1:0] backend_wb_recovery_safe_valid_i,
    output logic [SLICE_COUNT-1:0] backend_wb_recovery_safe_ready_o,

    output logic [SLICE_COUNT-1:0] dirty_present_o,
    output logic [SLICE_COUNT-1:0] wb_busy_o,
    output logic [RETRY_W-1:0] wb_retry_count_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] wb_terminal_failure_o,
    output logic [SLICE_COUNT-1:0] recovery_active_o,
    output logic [SLICE_COUNT-1:0] recovery_complete_pulse_o,
    output logic [COUNT_W-1:0] wb_pending_count_o,
    output logic [COUNT_W-1:0] wb_active_count_o,
    output logic commit_visibility_busy_o,
    output logic store_completion_busy_o,
    output logic [STORE_RETRY_W-1:0] store_retry_count_o,
    output logic store_terminal_failure_o,
    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o,
    output logic protocol_error_o
);
    localparam logic [1:0] BACKEND_KIND_READ       = 2'b00;
    localparam logic [1:0] BACKEND_KIND_STORE_WORD = 2'b10;

    logic p25_backend_valid, p25_backend_ready;
    logic [1:0] p25_backend_kind;
    logic [BACKEND_READ_TAG_W-1:0] p25_backend_read_tag;
    logic [BACKEND_ATTEMPT_ID_W-1:0] p25_backend_wb_attempt_id;
    logic [LINE_ADDR_W-1:0] p25_backend_line_addr;
    logic [31:0] p25_backend_data [0:LINE_WORDS-1];
    logic [31:0] p25_backend_store_word_addr, p25_backend_store_wdata;
    logic p25_protocol_error;

    logic store_source_valid, store_source_ready;
    logic store_backend_valid, store_backend_ready;
    logic [STORE_ATTEMPT_ID_W-1:0] store_backend_attempt_id;
    logic [31:0] store_backend_word_addr, store_backend_wdata;
    logic store_guard_protocol_error;
    logic illegal_kind_error;
    integer word;

    always_comb begin
        store_source_valid = p25_backend_valid && p25_backend_kind == BACKEND_KIND_STORE_WORD;
        store_backend_ready = backend_cmd_ready_i;
        p25_backend_ready = 1'b0;

        backend_cmd_valid_o = 1'b0;
        backend_cmd_kind_o = BACKEND_KIND_READ;
        backend_cmd_read_tag_o = '0;
        backend_cmd_wb_attempt_id_o = '0;
        backend_cmd_store_attempt_id_o = '0;
        backend_cmd_line_addr_o = '0;
        backend_cmd_store_word_addr_o = '0;
        backend_cmd_store_wdata_o = '0;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            backend_cmd_data_o[word] = '0;

        /* Once captured, the guard exclusively owns the STORE_WORD boundary. */
        if (store_backend_valid) begin
            backend_cmd_valid_o = 1'b1;
            backend_cmd_kind_o = BACKEND_KIND_STORE_WORD;
            backend_cmd_store_attempt_id_o = store_backend_attempt_id;
            backend_cmd_store_word_addr_o = store_backend_word_addr;
            backend_cmd_store_wdata_o = store_backend_wdata;
        end else if (!store_completion_busy_o && p25_backend_valid
                     && p25_backend_kind != BACKEND_KIND_STORE_WORD) begin
            backend_cmd_valid_o = 1'b1;
            backend_cmd_kind_o = p25_backend_kind;
            backend_cmd_read_tag_o = p25_backend_read_tag;
            backend_cmd_wb_attempt_id_o = p25_backend_wb_attempt_id;
            backend_cmd_line_addr_o = p25_backend_line_addr;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                backend_cmd_data_o[word] = p25_backend_data[word];
            p25_backend_ready = backend_cmd_ready_i;
        end

        if (store_source_valid)
            p25_backend_ready = store_source_ready;

        illegal_kind_error = p25_backend_valid && p25_backend_kind == 2'b11;
        protocol_error_o = p25_protocol_error || store_guard_protocol_error || illegal_kind_error;
    end

    a0_store_word_completion_guard #(
        .WRITE_ID_W(STORE_WRITE_ID_W), .MAX_RETRIES(MAX_STORE_RETRIES)
    ) u_store_completion_guard (
        .clk(clk), .rst_n(rst_n),
        .store_valid_i(store_source_valid), .store_ready_o(store_source_ready),
        .store_word_addr_i(p25_backend_store_word_addr), .store_wdata_i(p25_backend_store_wdata),
        .backend_store_valid_o(store_backend_valid), .backend_store_ready_i(store_backend_ready),
        .backend_store_attempt_id_o(store_backend_attempt_id),
        .backend_store_word_addr_o(store_backend_word_addr), .backend_store_wdata_o(store_backend_wdata),
        .backend_store_status_valid_i(backend_store_status_valid_i),
        .backend_store_status_attempt_id_i(backend_store_status_attempt_id_i),
        .backend_store_status_success_i(backend_store_status_success_i),
        .backend_store_status_retryable_i(backend_store_status_retryable_i),
        .busy_o(store_completion_busy_o), .retry_count_o(store_retry_count_o),
        .terminal_failure_o(store_terminal_failure_o), .protocol_error_o(store_guard_protocol_error)
    );

    a0_production_store_commit_write_miss_visibility_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING), .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),
        .STORE_LANES(STORE_LANES), .SLICE_COUNT(SLICE_COUNT), .LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE), .WRITE_ID_W(WRITE_ID_W),
        .MAX_WB_RETRIES(MAX_WB_RETRIES), .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) u_p25 (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i), .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i), .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o), .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o), .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .commit_valid_i(commit_valid_i), .commit_ready_o(commit_ready_o),
        .commit_lane_mask_i(commit_lane_mask_i), .commit_word_addr_i(commit_word_addr_i),
        .commit_wdata_i(commit_wdata_i),
        .backend_cmd_valid_o(p25_backend_valid), .backend_cmd_ready_i(p25_backend_ready),
        .backend_cmd_kind_o(p25_backend_kind), .backend_cmd_read_tag_o(p25_backend_read_tag),
        .backend_cmd_wb_attempt_id_o(p25_backend_wb_attempt_id),
        .backend_cmd_line_addr_o(p25_backend_line_addr), .backend_cmd_data_o(p25_backend_data),
        .backend_cmd_store_word_addr_o(p25_backend_store_word_addr),
        .backend_cmd_store_wdata_o(p25_backend_store_wdata),
        .backend_read_resp_valid_i(backend_read_resp_valid_i), .backend_read_resp_tag_i(backend_read_resp_tag_i),
        .backend_read_resp_line_addr_i(backend_read_resp_line_addr_i),
        .backend_read_resp_fault_i(backend_read_resp_fault_i), .backend_read_resp_data_i(backend_read_resp_data_i),
        .backend_wb_status_valid_i(backend_wb_status_valid_i),
        .backend_wb_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_wb_status_success_i(backend_wb_status_success_i),
        .backend_wb_status_retryable_i(backend_wb_status_retryable_i),
        .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),
        .backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .dirty_present_o(dirty_present_o), .wb_busy_o(wb_busy_o), .wb_retry_count_o(wb_retry_count_o),
        .wb_terminal_failure_o(wb_terminal_failure_o), .recovery_active_o(recovery_active_o),
        .recovery_complete_pulse_o(recovery_complete_pulse_o), .wb_pending_count_o(wb_pending_count_o),
        .wb_active_count_o(wb_active_count_o), .commit_visibility_busy_o(commit_visibility_busy_o),
        .line_resp_tag_error_o(line_resp_tag_error_o), .line_resp_overflow_o(line_resp_overflow_o),
        .protocol_error_o(p25_protocol_error)
    );
endmodule
