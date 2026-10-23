`timescale 1ns/1ps

/*
 * PROD-SEAM-P23: P22 multi-client dirty/recoverable L2 composed behind one
 * fair, backpressure-safe line backend command boundary.
 *
 * Read commands carry {home_slice, global_requester_tag}; durable writeback
 * commands carry the opaque P21/P22 writeback attempt id. Read responses and
 * writeback status remain explicitly typed on return and are never inferred
 * from address or payload.
 */
module a0_mc_noc_dirty_l2_unified_backend_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer SLICE_COUNT = 4,
    parameter integer STORE_LANES_PER_SLICE = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT_PER_SLICE = 64,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
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
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1)
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

    input logic [SLICE_COUNT-1:0] slice_store_valid_i,
    output logic [SLICE_COUNT-1:0] slice_store_ready_o,
    input logic [STORE_LANES_PER_SLICE-1:0] slice_store_lane_mask_i [0:SLICE_COUNT-1],
    input logic [31:0] slice_store_word_addr_i [0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1],
    input logic [31:0] slice_store_wdata_i [0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1],
    output logic [STORE_LANES_PER_SLICE-1:0] slice_store_hit_mask_o [0:SLICE_COUNT-1],
    output logic [STORE_LANES_PER_SLICE-1:0] slice_store_miss_mask_o [0:SLICE_COUNT-1],

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_cmd_wb_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,
    output logic [31:0] backend_cmd_data_o [0:LINE_WORDS-1],

    input logic backend_read_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_read_resp_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_read_resp_line_addr_i,
    input logic backend_read_resp_fault_i,
    input logic [31:0] backend_read_resp_data_i [0:LINE_WORDS-1],

    input logic backend_wb_status_valid_i,
    input logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,
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
    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o,
    output logic protocol_error_o
);
    logic [SLICE_COUNT-1:0] line_mem_req_valid;
    logic [SLICE_COUNT-1:0] line_mem_req_ready;
    logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] line_mem_resp_valid;
    logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] line_mem_resp_fault;
    logic [31:0] line_mem_resp_data [0:SLICE_COUNT-1][0:LINE_WORDS-1];

    logic wb_valid;
    logic wb_ready;
    logic [BACKEND_ATTEMPT_ID_W-1:0] wb_attempt_id;
    logic [LINE_ADDR_W-1:0] wb_line_addr;
    logic [31:0] wb_data [0:LINE_WORDS-1];
    logic wb_status_valid;
    logic wb_capture_ready;
    logic wb_buf_valid_q;
    logic [BACKEND_ATTEMPT_ID_W-1:0] wb_buf_attempt_q;
    logic [LINE_ADDR_W-1:0] wb_buf_line_q;
    logic [31:0] wb_buf_data_q [0:LINE_WORDS-1];
    integer wb_word;
    logic [BACKEND_ATTEMPT_ID_W-1:0] wb_status_attempt_id;
    logic wb_status_success;
    logic wb_status_retryable;
    logic p22_protocol_error;
    logic read_resp_protocol_error;

    initial begin
        if (SLICE_COUNT < 1 || (SLICE_COUNT & (SLICE_COUNT - 1)) != 0)
            $fatal(1, "P23 SLICE_COUNT must be a power of two >=1");
        if (BACKEND_READ_TAG_W != SLICE_ID_W + GLOBAL_TAG_W)
            $fatal(1, "P23 backend read tag width inconsistent");
    end

    a0_mc_noc_multislice_recoverable_writeback_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING), .SLICE_COUNT(SLICE_COUNT),
        .STORE_LANES_PER_SLICE(STORE_LANES_PER_SLICE), .LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE), .WRITE_ID_W(WRITE_ID_W),
        .MAX_WB_RETRIES(MAX_WB_RETRIES), .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) u_p22 (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i), .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i), .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o), .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o), .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .slice_store_valid_i(slice_store_valid_i), .slice_store_ready_o(slice_store_ready_o),
        .slice_store_lane_mask_i(slice_store_lane_mask_i), .slice_store_word_addr_i(slice_store_word_addr_i),
        .slice_store_wdata_i(slice_store_wdata_i), .slice_store_hit_mask_o(slice_store_hit_mask_o),
        .slice_store_miss_mask_o(slice_store_miss_mask_o),
        .line_mem_req_valid_o(line_mem_req_valid), .line_mem_req_ready_i(line_mem_req_ready),
        .line_mem_req_global_tag_o(line_mem_req_global_tag), .line_mem_req_line_addr_o(line_mem_req_line_addr),
        .line_mem_resp_valid_i(line_mem_resp_valid), .line_mem_resp_global_tag_i(line_mem_resp_global_tag),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr), .line_mem_resp_fault_i(line_mem_resp_fault),
        .line_mem_resp_data_i(line_mem_resp_data),
        .backend_wb_valid_o(wb_valid), .backend_wb_ready_i(wb_capture_ready),
        .backend_wb_attempt_id_o(wb_attempt_id), .backend_wb_line_addr_o(wb_line_addr), .backend_wb_data_o(wb_data),
        .backend_wb_status_valid_i(wb_status_valid), .backend_wb_status_attempt_id_i(wb_status_attempt_id),
        .backend_wb_status_success_i(wb_status_success), .backend_wb_status_retryable_i(wb_status_retryable),
        .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),
        .backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .dirty_present_o(dirty_present_o), .wb_busy_o(wb_busy_o), .wb_retry_count_o(wb_retry_count_o),
        .wb_terminal_failure_o(wb_terminal_failure_o), .recovery_active_o(recovery_active_o),
        .recovery_complete_pulse_o(recovery_complete_pulse_o), .wb_pending_count_o(wb_pending_count_o),
        .wb_active_count_o(wb_active_count_o), .line_resp_tag_error_o(line_resp_tag_error_o),
        .line_resp_overflow_o(line_resp_overflow_o), .protocol_error_o(p22_protocol_error)
    );

    a0_l2_unified_line_backend_arbiter #(
        .READ_PORT_COUNT(SLICE_COUNT), .LINE_WORDS(LINE_WORDS),
        .GLOBAL_TAG_W(GLOBAL_TAG_W), .LINE_ADDR_W(LINE_ADDR_W),
        .WB_ATTEMPT_ID_W(BACKEND_ATTEMPT_ID_W)
    ) u_backend (
        .clk(clk), .rst_n(rst_n),
        .read_valid_i(line_mem_req_valid), .read_ready_o(line_mem_req_ready),
        .read_global_tag_i(line_mem_req_global_tag), .read_line_addr_i(line_mem_req_line_addr),
        .wb_valid_i(wb_buf_valid_q), .wb_ready_o(wb_ready), .wb_attempt_id_i(wb_buf_attempt_q),
        .wb_line_addr_i(wb_buf_line_q), .wb_data_i(wb_buf_data_q),
        .backend_cmd_valid_o(backend_cmd_valid_o), .backend_cmd_ready_i(backend_cmd_ready_i),
        .backend_cmd_write_o(backend_cmd_write_o), .backend_cmd_read_tag_o(backend_cmd_read_tag_o),
        .backend_cmd_wb_attempt_id_o(backend_cmd_wb_attempt_id_o), .backend_cmd_line_addr_o(backend_cmd_line_addr_o),
        .backend_cmd_data_o(backend_cmd_data_o),
        .backend_read_resp_valid_i(backend_read_resp_valid_i), .backend_read_resp_tag_i(backend_read_resp_tag_i),
        .backend_read_resp_line_addr_i(backend_read_resp_line_addr_i), .backend_read_resp_fault_i(backend_read_resp_fault_i),
        .backend_read_resp_data_i(backend_read_resp_data_i),
        .read_resp_valid_o(line_mem_resp_valid), .read_resp_global_tag_o(line_mem_resp_global_tag),
        .read_resp_line_addr_o(line_mem_resp_line_addr), .read_resp_fault_o(line_mem_resp_fault),
        .read_resp_data_o(line_mem_resp_data),
        .backend_wb_status_valid_i(backend_wb_status_valid_i),
        .backend_wb_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_wb_status_success_i(backend_wb_status_success_i),
        .backend_wb_status_retryable_i(backend_wb_status_retryable_i),
        .wb_status_valid_o(wb_status_valid), .wb_status_attempt_id_o(wb_status_attempt_id),
        .wb_status_success_o(wb_status_success), .wb_status_retryable_o(wb_status_retryable),
        .read_resp_protocol_error_o(read_resp_protocol_error)
    );

    // Decouple the frozen P20/P22 writeback producer from P23 arbitration.
    // Upstream ready depends only on registered buffer occupancy, never on
    // upstream valid, so the unified backend cannot create a valid/ready loop.
    assign wb_capture_ready = rst_n && !wb_buf_valid_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_buf_valid_q <= 1'b0;
            wb_buf_attempt_q <= '0;
            wb_buf_line_q <= '0;
            for (wb_word = 0; wb_word < LINE_WORDS; wb_word = wb_word + 1)
                wb_buf_data_q[wb_word] <= '0;
        end else begin
            if (wb_buf_valid_q && wb_ready)
                wb_buf_valid_q <= 1'b0;
            if (wb_valid && wb_capture_ready) begin
                wb_buf_valid_q <= 1'b1;
                wb_buf_attempt_q <= wb_attempt_id;
                wb_buf_line_q <= wb_line_addr;
                for (wb_word = 0; wb_word < LINE_WORDS; wb_word = wb_word + 1)
                    wb_buf_data_q[wb_word] <= wb_data[wb_word];
            end
        end
    end

    assign protocol_error_o = p22_protocol_error | read_resp_protocol_error;
endmodule
