`timescale 1ns/1ps

/* PROD-SEAM-P30: preserve P29 and qualify each physical STORE_WORD attempt
 * with a separate generation.  Generation allocation survives P29 local
 * rearm.  Reusing the finite generation namespace requires a live backend
 * proof that every earlier STORE status is drained and cannot return.
 *
 * P29 resets the complete cache/read/writeback domain.  This wrapper permits
 * that reset only after an actual architectural abort and source withdrawal.
 * The external reset-domain certificate proves that no outstanding backend
 * READ response or WRITEBACK status can arrive.  Failed STORE reuse safety
 * is a separate input; local client, cache and WRITEBACK state is checked
 * independently.  A nonempty domain remains halted; this module does not
 * implement cache flushing or selective reset.
 * Global rst_n independently requires all backend domains to be quiescent.
 */
module a0_production_store_commit_generation_subsystem #(
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
    parameter integer STORE_GENERATION_W = 8,
    parameter integer P29_STORE_ATTEMPT_ID_W = STORE_WRITE_ID_W + STORE_RETRY_W,
    parameter integer STORE_ATTEMPT_ID_W = STORE_GENERATION_W + P29_STORE_ATTEMPT_ID_W,
    parameter integer STORE_STATUS_TIMEOUT_CYCLES = 16,
    parameter integer STORE_STATUS_TIMER_W = (STORE_STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STORE_STATUS_TIMEOUT_CYCLES),
    parameter integer COMMIT_PORT_ID_W = (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer CLIENT_READ_COUNT_W = ((CLIENT_COUNT * CLIENT_MAX_OUTSTANDING) < 1)
        ? 1 : $clog2(CLIENT_COUNT * CLIENT_MAX_OUTSTANDING + 1)
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
    input logic backend_store_all_generations_quiescent_i,
    // Current external READ/WRITEBACK drain certificate, not a local idle hint.
    input logic backend_recovery_domain_quiescent_i,
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
    output logic [STORE_GENERATION_W-1:0] store_generation_next_o,
    output logic store_generation_wrap_pending_o,
    output logic store_status_rejected_o,
    output logic recovery_reset_blocked_o,
    output logic [CLIENT_READ_COUNT_W-1:0] client_read_outstanding_o,
    output logic protocol_error_o
);
    localparam logic [1:0] BACKEND_KIND_STORE_WORD = 2'b10;
    localparam integer MAX_CLIENT_READS = CLIENT_COUNT * CLIENT_MAX_OUTSTANDING;

    logic [STORE_GENERATION_W-1:0] generation_next_q;
    logic generation_wrap_pending_q;
    logic store_attempt_live_q;
    logic [STORE_ATTEMPT_ID_W-1:0] live_store_attempt_id_q;
    logic store_status_rejected_q;
    logic [CLIENT_READ_COUNT_W-1:0] client_read_outstanding_q;
    logic read_count_protocol_error_q;
    logic abort_seen_q, aborted_source_withdrawn_q;
    logic [COMMIT_PORT_ID_W-1:0] aborted_port_q;

    logic p29_backend_cmd_valid, p29_backend_cmd_ready;
    logic [P29_STORE_ATTEMPT_ID_W-1:0] p29_backend_cmd_store_attempt_id;
    logic p29_backend_store_status_valid;
    logic [P29_STORE_ATTEMPT_ID_W-1:0] p29_backend_store_status_attempt_id;
    logic p29_backend_store_status_reuse_safe;
    logic p29_recovery_required, p29_rearm, p29_protocol_error;
    logic [CLIENT_COUNT-1:0] p29_client_req_valid, p29_client_req_ready;
    logic [CLIENT_COUNT-1:0] p29_client_resp_valid;
    logic [COMMIT_PORT_COUNT-1:0] p29_commit_valid, p29_commit_ready;
    logic [COMMIT_PORT_COUNT-1:0] p29_commit_abort;

    logic client_admission_fenced;
    logic store_issue_enabled, store_cmd_fire;
    logic live_status_match, command_status_match;
    logic generation_wrap_release;
    logic recovery_join, aborted_source_withdrawn;
    logic read_count_invalid;
    integer read_accept_count, read_response_count, read_count_next;

    initial begin
        if (STORE_GENERATION_W < 1) $fatal(1, "P30 STORE_GENERATION_W must be >=1");
        if (STORE_WRITE_ID_W < 1) $fatal(1, "P30 STORE_WRITE_ID_W must be >=1");
        if (MAX_STORE_RETRIES < 0) $fatal(1, "P30 MAX_STORE_RETRIES must be >=0");
        if (STORE_RETRY_W != ((MAX_STORE_RETRIES < 1) ? 1 : $clog2(MAX_STORE_RETRIES + 1)))
            $fatal(1, "P30 STORE_RETRY_W must match frozen P29");
        if (P29_STORE_ATTEMPT_ID_W != STORE_WRITE_ID_W + STORE_RETRY_W)
            $fatal(1, "P30 P29_STORE_ATTEMPT_ID_W must preserve the whole P29 ID");
        if (STORE_ATTEMPT_ID_W != STORE_GENERATION_W + P29_STORE_ATTEMPT_ID_W)
            $fatal(1, "P30 STORE_ATTEMPT_ID_W must include the separate generation");
        if (CLIENT_COUNT < 1 || CLIENT_MAX_OUTSTANDING < 1)
            $fatal(1, "P30 client counts must be positive");
        if (CLIENT_READ_COUNT_W < $clog2(MAX_CLIENT_READS + 1) || CLIENT_READ_COUNT_W > 31)
            $fatal(1, "P30 CLIENT_READ_COUNT_W cannot represent the bounded count safely");
        if (COMMIT_PORT_COUNT < 1
            || COMMIT_PORT_ID_W < ((COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT)))
            $fatal(1, "P30 commit port identity width is insufficient");
    end

    /* Allocation gates both sides of the frozen command handshake.  Existing
     * READ and WRITEBACK identities and command scheduling are unchanged. */
    always_comb begin
        store_issue_enabled = !generation_wrap_pending_q;
        backend_cmd_valid_o = p29_backend_cmd_valid && rst_n && !p29_rearm
            && (backend_cmd_kind_o != BACKEND_KIND_STORE_WORD || store_issue_enabled);
        p29_backend_cmd_ready = backend_cmd_ready_i && rst_n && !p29_rearm
            && (backend_cmd_kind_o != BACKEND_KIND_STORE_WORD || store_issue_enabled);
        backend_cmd_store_attempt_id_o = {generation_next_q, p29_backend_cmd_store_attempt_id};
        store_cmd_fire = backend_cmd_valid_o && backend_cmd_ready_i
            && backend_cmd_kind_o == BACKEND_KIND_STORE_WORD;

        live_status_match = store_attempt_live_q && store_status_timeout_live_o
            && backend_store_status_attempt_id_i == live_store_attempt_id_q;
        command_status_match = store_cmd_fire
            && backend_store_status_attempt_id_i == backend_cmd_store_attempt_id_o;
        p29_backend_store_status_valid = backend_store_status_valid_i && rst_n && !p29_rearm
            && (live_status_match || command_status_match);
        p29_backend_store_status_attempt_id =
            backend_store_status_attempt_id_i[P29_STORE_ATTEMPT_ID_W-1:0];

        /* A proof supplied before wrapping is pending is not remembered.
         * In particular, the last allocated attempt can finish while the
         * allocator is blocked, and status traffic prevents proof acceptance. */
        generation_wrap_release = generation_wrap_pending_q && !store_attempt_live_q
            && !store_status_timeout_live_o && !backend_store_status_valid_i
            && backend_store_all_generations_quiescent_i;

        store_generation_next_o = generation_next_q;
        store_generation_wrap_pending_o = generation_wrap_pending_q;
        store_status_rejected_o = store_status_rejected_q;
    end

    assign client_admission_fenced = !rst_n || store_terminal_failure_o || commit_fault_valid_o
        || p29_recovery_required || p29_rearm || abort_seen_q || read_count_protocol_error_q;
    assign p29_client_req_valid = client_admission_fenced ? '0 : client_req_valid_i;
    assign client_req_ready_o = client_admission_fenced ? '0 : p29_client_req_ready;
    assign client_resp_valid_o = (rst_n && !p29_rearm) ? p29_client_resp_valid : '0;

    /* Only reset masks pending commits.  Unselected sources remain
     * pending across recovery and need not violate their hold contract. */
    assign p29_commit_valid = (rst_n && !p29_rearm) ? commit_valid_i : '0;
    assign commit_ready_o = (rst_n && !p29_rearm) ? p29_commit_ready : '0;
    assign commit_abort_o = (rst_n && !p29_rearm) ? p29_commit_abort : '0;

    always_comb begin
        read_accept_count = 0;
        read_response_count = 0;
        for (integer client_c = 0; client_c < CLIENT_COUNT; client_c = client_c + 1) begin
            if (client_req_valid_i[client_c] && client_req_ready_o[client_c])
                read_accept_count = read_accept_count + 1;
            if (client_resp_valid_o[client_c])
                read_response_count = read_response_count + 1;
        end
        read_count_next = integer'(client_read_outstanding_q) + read_accept_count - read_response_count;
        read_count_invalid = read_count_next < 0 || read_count_next > MAX_CLIENT_READS;
        client_read_outstanding_o = client_read_outstanding_q;
        protocol_error_o = p29_protocol_error || read_count_protocol_error_q || read_count_invalid;
    end

    always_comb begin
        aborted_source_withdrawn = aborted_source_withdrawn_q
            || (abort_seen_q && !commit_valid_i[integer'(aborted_port_q)]);
        recovery_join = rst_n && !p29_rearm && p29_recovery_required
            && abort_seen_q && aborted_source_withdrawn
            && backend_store_status_reuse_safe_i && backend_recovery_domain_quiescent_i
            && client_read_outstanding_q == '0 && read_accept_count == 0
            && !(|p29_client_resp_valid) && !backend_read_resp_valid_i && !backend_wb_status_valid_i
            && !(|dirty_present_o) && !(|wb_busy_o) && !(|wb_terminal_failure_o)
            && wb_pending_count_o == '0 && wb_active_count_o == '0
            && !(|recovery_active_o) && !(|recovery_complete_pulse_o)
            && !p29_backend_cmd_valid && !store_attempt_live_q && !store_status_timeout_live_o
            && !backend_store_status_valid_i && !protocol_error_o;
        p29_backend_store_status_reuse_safe = recovery_join;
        recovery_required_o = p29_recovery_required;
        recovery_rearm_pulse_o = p29_rearm;
        recovery_reset_blocked_o = p29_recovery_required && !p29_rearm && !recovery_join;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            generation_next_q <= '0;
            generation_wrap_pending_q <= 1'b0;
            store_attempt_live_q <= 1'b0;
            live_store_attempt_id_q <= '0;
            store_status_rejected_q <= 1'b0;
            client_read_outstanding_q <= '0;
            read_count_protocol_error_q <= 1'b0;
            abort_seen_q <= 1'b0;
            aborted_source_withdrawn_q <= 1'b0;
            aborted_port_q <= '0;
        end else begin
            if (store_cmd_fire) begin
                live_store_attempt_id_q <= backend_cmd_store_attempt_id_o;
                store_attempt_live_q <= !p29_backend_store_status_valid;
                generation_next_q <= generation_next_q + STORE_GENERATION_W'(1);
                if (&generation_next_q)
                    generation_wrap_pending_q <= 1'b1;
            end else begin
                if (p29_backend_store_status_valid || store_status_timeout_pulse_o)
                    store_attempt_live_q <= 1'b0;
                if (generation_wrap_release)
                    generation_wrap_pending_q <= 1'b0;
            end

            if (backend_store_status_valid_i && !p29_backend_store_status_valid)
                store_status_rejected_q <= 1'b1;

            if (read_count_invalid) begin
                read_count_protocol_error_q <= 1'b1;
            end else if (!read_count_protocol_error_q) begin
                client_read_outstanding_q <= CLIENT_READ_COUNT_W'(read_count_next);
            end

            if (recovery_join) begin
                abort_seen_q <= 1'b0;
                aborted_source_withdrawn_q <= 1'b0;
            end else if (|commit_abort_o) begin
                abort_seen_q <= 1'b1;
                aborted_source_withdrawn_q <= 1'b0;
                for (integer port_s = 0; port_s < COMMIT_PORT_COUNT; port_s = port_s + 1) begin
                    if (commit_abort_o[port_s])
                        aborted_port_q <= COMMIT_PORT_ID_W'(port_s);
                end
            end else if (abort_seen_q && !commit_valid_i[integer'(aborted_port_q)]) begin
                aborted_source_withdrawn_q <= 1'b1;
            end
        end
    end

    a0_production_store_commit_recoverable_fault_subsystem #(
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
        .STORE_RETRY_W(STORE_RETRY_W), .STORE_ATTEMPT_ID_W(P29_STORE_ATTEMPT_ID_W),
        .STORE_STATUS_TIMEOUT_CYCLES(STORE_STATUS_TIMEOUT_CYCLES),
        .STORE_STATUS_TIMER_W(STORE_STATUS_TIMER_W), .COMMIT_PORT_ID_W(COMMIT_PORT_ID_W)
    ) u_p29 (
        .client_req_valid_i(p29_client_req_valid), .client_req_ready_o(p29_client_req_ready),
        .client_resp_valid_o(p29_client_resp_valid),
        .commit_valid_i(p29_commit_valid), .commit_ready_o(p29_commit_ready), .commit_abort_o(p29_commit_abort),
        .backend_cmd_valid_o(p29_backend_cmd_valid), .backend_cmd_ready_i(p29_backend_cmd_ready),
        .backend_cmd_store_attempt_id_o(p29_backend_cmd_store_attempt_id),
        .backend_store_status_valid_i(p29_backend_store_status_valid),
        .backend_store_status_attempt_id_i(p29_backend_store_status_attempt_id),
        .backend_store_status_reuse_safe_i(p29_backend_store_status_reuse_safe),
        .recovery_required_o(p29_recovery_required), .recovery_rearm_pulse_o(p29_rearm),
        .protocol_error_o(p29_protocol_error),
        .*
    );
endmodule
