`timescale 1ns/1ps

/*
 * PROD-SEAM-P21 composition: multiple frozen P19 recoverable dirty slices
 * share one frozen P20 backend writeback queue/arbitration boundary.
 *
 * Durability remains owned by each P19 slice: P20 only captures/issues commands
 * and restores status by {slice_id, local_attempt_id}. A victim is therefore
 * released only by the exact slice-local SUCCESS observed by P19. Recovery-safe
 * acknowledgement is explicit per slice so one failed source can recover without
 * resetting or synthetically releasing any peer slice.
 */
module a0_l2_multislice_recoverable_writeback_subsystem #(
    parameter integer SLICE_COUNT = 4,
    parameter integer STORE_LANES = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT = 64,
    parameter integer GLOBAL_TAG_W = 8,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer RETRY_W = (MAX_WB_RETRIES < 1) ? 1 : $clog2(MAX_WB_RETRIES + 1),
    parameter integer LOCAL_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer BACKEND_ATTEMPT_ID_W = SLICE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic [SLICE_COUNT-1:0] line_req_valid_i,
    output logic [SLICE_COUNT-1:0] line_req_ready_o,
    input logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i [0:SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] line_req_line_addr_i [0:SLICE_COUNT-1],

    output logic [SLICE_COUNT-1:0] line_mem_req_valid_o,
    input logic [SLICE_COUNT-1:0] line_mem_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o [0:SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o [0:SLICE_COUNT-1],

    input logic [SLICE_COUNT-1:0] line_mem_resp_valid_i,
    input logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i [0:SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i [0:SLICE_COUNT-1],
    input logic [SLICE_COUNT-1:0] line_mem_resp_fault_i,
    input logic [31:0] line_mem_resp_data_i [0:SLICE_COUNT-1][0:LINE_WORDS-1],

    output logic [SLICE_COUNT-1:0] line_resp_valid_o,
    output logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o [0:SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] line_resp_fault_o,
    output logic [31:0] line_resp_data_o [0:SLICE_COUNT-1][0:LINE_WORDS-1],

    input logic [SLICE_COUNT-1:0] store_valid_i,
    output logic [SLICE_COUNT-1:0] store_ready_o,
    input logic [STORE_LANES-1:0] store_lane_mask_i [0:SLICE_COUNT-1],
    input logic [31:0] store_word_addr_i [0:SLICE_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] store_wdata_i [0:SLICE_COUNT-1][0:STORE_LANES-1],
    output logic [STORE_LANES-1:0] store_hit_mask_o [0:SLICE_COUNT-1],
    output logic [STORE_LANES-1:0] store_miss_mask_o [0:SLICE_COUNT-1],

    output logic backend_wb_valid_o,
    input logic backend_wb_ready_i,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_wb_line_addr_o,
    output logic [31:0] backend_wb_data_o [0:LINE_WORDS-1],

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
    output logic protocol_error_o
);
    logic [SLICE_COUNT-1:0] slice_wb_valid;
    logic [SLICE_COUNT-1:0] slice_wb_ready;
    logic [LOCAL_ATTEMPT_ID_W-1:0] slice_wb_attempt_id [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_wb_line_addr [0:SLICE_COUNT-1];
    logic [31:0] slice_wb_data [0:SLICE_COUNT-1][0:LINE_WORDS-1];

    logic [SLICE_COUNT-1:0] slice_status_valid;
    logic [LOCAL_ATTEMPT_ID_W-1:0] slice_status_attempt_id [0:SLICE_COUNT-1];
    logic slice_status_success [0:SLICE_COUNT-1];
    logic slice_status_retryable [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] slice_protocol_error;
    logic queue_protocol_error;

    initial begin
        if (SLICE_COUNT < 1) $fatal(1, "P21 SLICE_COUNT must be >=1");
    end

    genvar slice;
    generate
        for (slice = 0; slice < SLICE_COUNT; slice = slice + 1) begin : g_slice
            a0_l2_recoverable_writeback_slice #(
                .STORE_LANES(STORE_LANES),
                .LINE_WORDS(LINE_WORDS),
                .SET_COUNT(SET_COUNT),
                .GLOBAL_TAG_W(GLOBAL_TAG_W),
                .WRITE_ID_W(WRITE_ID_W),
                .MAX_WB_RETRIES(MAX_WB_RETRIES)
            ) u_slice (
                .clk(clk),
                .rst_n(rst_n),
                .line_req_valid_i(line_req_valid_i[slice]),
                .line_req_ready_o(line_req_ready_o[slice]),
                .line_req_global_tag_i(line_req_global_tag_i[slice]),
                .line_req_line_addr_i(line_req_line_addr_i[slice]),
                .line_mem_req_valid_o(line_mem_req_valid_o[slice]),
                .line_mem_req_ready_i(line_mem_req_ready_i[slice]),
                .line_mem_req_global_tag_o(line_mem_req_global_tag_o[slice]),
                .line_mem_req_line_addr_o(line_mem_req_line_addr_o[slice]),
                .line_mem_resp_valid_i(line_mem_resp_valid_i[slice]),
                .line_mem_resp_global_tag_i(line_mem_resp_global_tag_i[slice]),
                .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i[slice]),
                .line_mem_resp_fault_i(line_mem_resp_fault_i[slice]),
                .line_mem_resp_data_i(line_mem_resp_data_i[slice]),
                .line_resp_valid_o(line_resp_valid_o[slice]),
                .line_resp_global_tag_o(line_resp_global_tag_o[slice]),
                .line_resp_line_addr_o(line_resp_line_addr_o[slice]),
                .line_resp_fault_o(line_resp_fault_o[slice]),
                .line_resp_data_o(line_resp_data_o[slice]),
                .store_valid_i(store_valid_i[slice]),
                .store_ready_o(store_ready_o[slice]),
                .store_lane_mask_i(store_lane_mask_i[slice]),
                .store_word_addr_i(store_word_addr_i[slice]),
                .store_wdata_i(store_wdata_i[slice]),
                .store_hit_mask_o(store_hit_mask_o[slice]),
                .store_miss_mask_o(store_miss_mask_o[slice]),
                .backend_wb_valid_o(slice_wb_valid[slice]),
                .backend_wb_ready_i(slice_wb_ready[slice]),
                .backend_wb_attempt_id_o(slice_wb_attempt_id[slice]),
                .backend_wb_line_addr_o(slice_wb_line_addr[slice]),
                .backend_wb_data_o(slice_wb_data[slice]),
                .backend_wb_status_valid_i(slice_status_valid[slice]),
                .backend_wb_status_attempt_id_i(slice_status_attempt_id[slice]),
                .backend_wb_status_success_i(slice_status_success[slice]),
                .backend_wb_status_retryable_i(slice_status_retryable[slice]),
                .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i[slice]),
                .backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o[slice]),
                .dirty_present_o(dirty_present_o[slice]),
                .wb_busy_o(wb_busy_o[slice]),
                .wb_retry_count_o(wb_retry_count_o[slice]),
                .wb_terminal_failure_o(wb_terminal_failure_o[slice]),
                .recovery_active_o(recovery_active_o[slice]),
                .recovery_complete_pulse_o(recovery_complete_pulse_o[slice]),
                .protocol_error_o(slice_protocol_error[slice])
            );
        end
    endgenerate

    a0_l2_multislice_writeback_queue #(
        .SOURCE_COUNT(SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LOCAL_ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W)
    ) u_queue (
        .clk(clk),
        .rst_n(rst_n),
        .src_valid_i(slice_wb_valid),
        .src_ready_o(slice_wb_ready),
        .src_attempt_id_i(slice_wb_attempt_id),
        .src_line_addr_i(slice_wb_line_addr),
        .src_data_i(slice_wb_data),
        .src_status_valid_o(slice_status_valid),
        .src_status_attempt_id_o(slice_status_attempt_id),
        .src_status_success_o(slice_status_success),
        .src_status_retryable_o(slice_status_retryable),
        .backend_valid_o(backend_wb_valid_o),
        .backend_ready_i(backend_wb_ready_i),
        .backend_attempt_id_o(backend_wb_attempt_id_o),
        .backend_line_addr_o(backend_wb_line_addr_o),
        .backend_data_o(backend_wb_data_o),
        .backend_status_valid_i(backend_wb_status_valid_i),
        .backend_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_status_success_i(backend_wb_status_success_i),
        .backend_status_retryable_i(backend_wb_status_retryable_i),
        .pending_count_o(wb_pending_count_o),
        .active_count_o(wb_active_count_o),
        .protocol_error_o(queue_protocol_error)
    );

    always_comb begin
        protocol_error_o = queue_protocol_error;
        for (integer pe = 0; pe < SLICE_COUNT; pe = pe + 1)
            protocol_error_o = protocol_error_o || slice_protocol_error[pe];
    end
endmodule
