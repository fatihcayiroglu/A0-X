`timescale 1ns/1ps

/* PROD-SEAM-P29: frozen P28 fault provenance plus bounded safe restart.
 * Recovery is legal only after P28 has completed its architectural abort and
 * the backend independently asserts that the failed STORE_WORD status epoch is
 * reuse-safe.  Early reuse-safe is intentionally not remembered.  A one-cycle
 * local reset rearms the frozen P28 chain while an external epoch remap keeps
 * the next STORE_WORD attempt distinct from the failed backend-visible ID. */
module a0_production_store_commit_recoverable_fault_subsystem #(
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
    parameter integer STORE_ATTEMPT_ID_W = STORE_WRITE_ID_W + STORE_RETRY_W,
    parameter integer STORE_STATUS_TIMEOUT_CYCLES = 16,
    parameter integer STORE_STATUS_TIMER_W = (STORE_STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STORE_STATUS_TIMEOUT_CYCLES),
    parameter integer COMMIT_PORT_ID_W = (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT)
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
    input logic backend_store_status_reuse_safe_i,
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
    output logic store_status_timeout_live_o,
    output logic [STORE_STATUS_TIMER_W-1:0] store_status_timeout_age_o,
    output logic store_status_timeout_pulse_o,
    output logic store_status_timeout_seen_o,
    output logic [COMMIT_PORT_COUNT-1:0] commit_abort_o,
    output logic commit_fault_valid_o,
    input logic commit_fault_ready_i,
    output logic [COMMIT_PORT_ID_W-1:0] commit_fault_port_id_o,
    output logic [STORE_LANES-1:0] commit_fault_lane_mask_o,
    output logic [31:0] commit_fault_word_addr_o [0:STORE_LANES-1],
    output logic [31:0] commit_fault_wdata_o [0:STORE_LANES-1],
    output logic commit_fault_store_timeout_o,
    output logic [STORE_RETRY_W-1:0] commit_fault_store_retry_count_o,
    output logic recovery_required_o,
    output logic recovery_rearm_pulse_o,
    output logic store_epoch_o,
    output logic protocol_error_o
);
    localparam logic [STORE_ATTEMPT_ID_W-1:0] STORE_EPOCH_MASK =
        (STORE_ATTEMPT_ID_W'(1) << STORE_RETRY_W);

    logic p28_rst_n;
    logic rearm_q;
    logic epoch_q;
    logic p28_recovery_required;
    logic p28_protocol_error;
    logic [STORE_ATTEMPT_ID_W-1:0] p28_backend_cmd_store_attempt_id;
    logic [STORE_ATTEMPT_ID_W-1:0] p28_backend_store_status_attempt_id;

    initial begin
        if (STORE_WRITE_ID_W < 1) $fatal(1, "P29 STORE_WRITE_ID_W must be >=1");
    end

    assign p28_rst_n = rst_n && !rearm_q;
    assign p28_backend_store_status_attempt_id = backend_store_status_attempt_id_i
        ^ (epoch_q ? STORE_EPOCH_MASK : '0);

    always_comb begin
        backend_cmd_store_attempt_id_o = p28_backend_cmd_store_attempt_id
            ^ (epoch_q ? STORE_EPOCH_MASK : '0);
        recovery_required_o = p28_recovery_required;
        recovery_rearm_pulse_o = rearm_q;
        store_epoch_o = epoch_q;
        protocol_error_o = p28_protocol_error;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rearm_q <= 1'b0;
            epoch_q <= 1'b0;
        end else begin
            rearm_q <= 1'b0;
            if (!rearm_q && p28_recovery_required && backend_store_status_reuse_safe_i) begin
                rearm_q <= 1'b1;
                epoch_q <= ~epoch_q;
            end
        end
    end

    a0_production_store_commit_fault_provenance_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING), .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),
        .STORE_LANES(STORE_LANES), .SLICE_COUNT(SLICE_COUNT), .LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE), .WRITE_ID_W(WRITE_ID_W),
        .MAX_WB_RETRIES(MAX_WB_RETRIES), .STORE_WRITE_ID_W(STORE_WRITE_ID_W),
        .MAX_STORE_RETRIES(MAX_STORE_RETRIES), .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W), .CLIENT_ID_W(CLIENT_ID_W), .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .SLICE_ID_W(SLICE_ID_W), .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT), .RETRY_W(RETRY_W),
        .LOCAL_ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W), .BACKEND_ATTEMPT_ID_W(BACKEND_ATTEMPT_ID_W),
        .BACKEND_READ_TAG_W(BACKEND_READ_TAG_W), .COUNT_W(COUNT_W),
        .STORE_RETRY_W(STORE_RETRY_W), .STORE_ATTEMPT_ID_W(STORE_ATTEMPT_ID_W),
        .STORE_STATUS_TIMEOUT_CYCLES(STORE_STATUS_TIMEOUT_CYCLES),
        .STORE_STATUS_TIMER_W(STORE_STATUS_TIMER_W), .COMMIT_PORT_ID_W(COMMIT_PORT_ID_W)
    ) u_p28 (
        .rst_n(p28_rst_n),
        .backend_cmd_store_attempt_id_o(p28_backend_cmd_store_attempt_id),
        .backend_store_status_attempt_id_i(p28_backend_store_status_attempt_id),
        .recovery_required_o(p28_recovery_required),
        .protocol_error_o(p28_protocol_error),
        .*
    );
endmodule
