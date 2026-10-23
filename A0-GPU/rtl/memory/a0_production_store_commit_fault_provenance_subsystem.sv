`timescale 1ns/1ps

/* PROD-SEAM-P28: frozen P27 plus exact commit fault/abort provenance. */
module a0_production_store_commit_fault_provenance_subsystem #(
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
    output logic protocol_error_o
);
    typedef enum logic [1:0] {IDLE, ACTIVE, FAULT, HALT} state_t;
    state_t state_q;

    logic [COMMIT_PORT_ID_W-1:0] rr_q, active_port_q, select_port, scan_port;
    logic select_found;
    logic [STORE_LANES-1:0] captured_lane_mask_q;
    logic [31:0] captured_word_addr_q [0:STORE_LANES-1];
    logic [31:0] captured_wdata_q [0:STORE_LANES-1];
    logic fault_store_timeout_q;
    logic [STORE_RETRY_W-1:0] fault_store_retry_count_q;
    logic wrapper_protocol_error_q;
    logic source_payload_match;

    logic [0:0] p27_commit_valid, p27_commit_ready;
    logic [STORE_LANES-1:0] p27_commit_lane_mask [0:0];
    logic [31:0] p27_commit_word_addr [0:0][0:STORE_LANES-1];
    logic [31:0] p27_commit_wdata [0:0][0:STORE_LANES-1];
    logic p27_protocol_error;

    integer scan_offset;

    initial begin
        if (COMMIT_PORT_COUNT < 1) $fatal(1, "P28 COMMIT_PORT_COUNT must be >=1");
        if (STORE_LANES < 1) $fatal(1, "P28 STORE_LANES must be >=1");
    end

    always_comb begin
        select_found = 1'b0;
        select_port = '0;
        scan_port = '0;
        if (state_q == IDLE) begin
            for (scan_offset = 0; scan_offset < COMMIT_PORT_COUNT; scan_offset = scan_offset + 1) begin
                scan_port = COMMIT_PORT_ID_W'((integer'(rr_q) + scan_offset) % COMMIT_PORT_COUNT);
                if (!select_found && commit_valid_i[integer'(scan_port)]) begin
                    select_found = 1'b1;
                    select_port = scan_port;
                end
            end
        end
    end

    always_comb begin
        source_payload_match = commit_valid_i[integer'(active_port_q)]
            && commit_lane_mask_i[integer'(active_port_q)] == captured_lane_mask_q;
        for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
            source_payload_match = source_payload_match
                && commit_word_addr_i[integer'(active_port_q)][lane_c] == captured_word_addr_q[lane_c]
                && commit_wdata_i[integer'(active_port_q)][lane_c] == captured_wdata_q[lane_c];
        end

        p27_commit_valid[0] = (state_q != IDLE);
        p27_commit_lane_mask[0] = captured_lane_mask_q;
        for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
            p27_commit_word_addr[0][lane_c] = captured_word_addr_q[lane_c];
            p27_commit_wdata[0][lane_c] = captured_wdata_q[lane_c];
        end

        commit_ready_o = '0;
        commit_abort_o = '0;
        if (state_q == ACTIVE && p27_commit_ready[0] && source_payload_match)
            commit_ready_o[integer'(active_port_q)] = 1'b1;
        if (state_q == FAULT && commit_fault_ready_i && source_payload_match)
            commit_abort_o[integer'(active_port_q)] = 1'b1;

        commit_fault_valid_o = (state_q == FAULT);
        commit_fault_port_id_o = active_port_q;
        commit_fault_lane_mask_o = captured_lane_mask_q;
        for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
            commit_fault_word_addr_o[lane_c] = captured_word_addr_q[lane_c];
            commit_fault_wdata_o[lane_c] = captured_wdata_q[lane_c];
        end
        commit_fault_store_timeout_o = fault_store_timeout_q;
        commit_fault_store_retry_count_o = fault_store_retry_count_q;
        recovery_required_o = (state_q == HALT);
        protocol_error_o = p27_protocol_error || wrapper_protocol_error_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            rr_q <= '0;
            active_port_q <= '0;
            captured_lane_mask_q <= '0;
            fault_store_timeout_q <= 1'b0;
            fault_store_retry_count_q <= '0;
            wrapper_protocol_error_q <= 1'b0;
            for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                captured_word_addr_q[lane_s] <= '0;
                captured_wdata_q[lane_s] <= '0;
            end
        end else begin
            case (state_q)
                IDLE: begin
                    fault_store_timeout_q <= 1'b0;
                    fault_store_retry_count_q <= '0;
                    if (select_found) begin
                        active_port_q <= select_port;
                        captured_lane_mask_q <= commit_lane_mask_i[integer'(select_port)];
                        for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                            captured_word_addr_q[lane_s] <= commit_word_addr_i[integer'(select_port)][lane_s];
                            captured_wdata_q[lane_s] <= commit_wdata_i[integer'(select_port)][lane_s];
                        end
                        state_q <= ACTIVE;
                    end
                end
                ACTIVE: begin
                    if (!source_payload_match)
                        wrapper_protocol_error_q <= 1'b1;
                    if (store_terminal_failure_o) begin
                        fault_store_timeout_q <= store_status_timeout_seen_o;
                        fault_store_retry_count_q <= store_retry_count_o;
                        state_q <= FAULT;
                    end else if (p27_commit_ready[0]) begin
                        if (source_payload_match) begin
                            if (integer'(active_port_q) == COMMIT_PORT_COUNT-1) rr_q <= '0;
                            else rr_q <= active_port_q + COMMIT_PORT_ID_W'(1);
                            state_q <= IDLE;
                        end else begin
                            state_q <= HALT;
                        end
                    end
                end
                FAULT: begin
                    if (!source_payload_match)
                        wrapper_protocol_error_q <= 1'b1;
                    if (commit_fault_ready_i && source_payload_match) begin
                        if (integer'(active_port_q) == COMMIT_PORT_COUNT-1) rr_q <= '0;
                        else rr_q <= active_port_q + COMMIT_PORT_ID_W'(1);
                        state_q <= HALT;
                    end
                end
                default: state_q <= HALT;
            endcase
        end
    end

    a0_production_store_commit_timed_miss_visibility_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING), .COMMIT_PORT_COUNT(1),
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
        .STORE_STATUS_TIMER_W(STORE_STATUS_TIMER_W)
    ) u_p27 (
        .commit_valid_i(p27_commit_valid), .commit_ready_o(p27_commit_ready),
        .commit_lane_mask_i(p27_commit_lane_mask), .commit_word_addr_i(p27_commit_word_addr),
        .commit_wdata_i(p27_commit_wdata), .protocol_error_o(p27_protocol_error), .*
    );
endmodule
