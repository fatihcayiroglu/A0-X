`timescale 1ns/1ps

/* PROD-SEAM-P32: captured production commit, persistent P24 classification,
 * and explicit STORE-only fault recovery.  P24 completes its own transaction
 * before the first miss word is offered.  Its cache/read/writeback domain is
 * never reset here.  A failed word stays presented through the STORE-guard
 * reset edge; remaining miss lanes are cancelled by an explicit abort path,
 * never by a fabricated STORE success. */
module a0_store_commit_progress_frontend #(
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer SLICE_COUNT = 4,
    parameter integer STORE_RETRY_W = 2,
    parameter integer COMMIT_PORT_ID_W = (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer STORE_LANE_ID_W = (STORE_LANES <= 1) ? 1 : $clog2(STORE_LANES)
) (
    input logic clk,
    input logic rst_n,

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    output logic [COMMIT_PORT_COUNT-1:0] commit_ready_o,
    input logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    output logic [0:0] p24_commit_valid_o,
    input logic [0:0] p24_commit_ready_i,
    output logic [STORE_LANES-1:0] p24_commit_lane_mask_o [0:0],
    output logic [31:0] p24_commit_word_addr_o [0:0][0:STORE_LANES-1],
    output logic [31:0] p24_commit_wdata_o [0:0][0:STORE_LANES-1],
    input logic [STORE_LANES-1:0] p24_slice_store_hit_mask_i [0:SLICE_COUNT-1],
    input logic [STORE_LANES-1:0] p24_slice_store_miss_mask_i [0:SLICE_COUNT-1],
    input logic p24_commit_router_busy_i,

    output logic store_valid_o,
    input logic store_ready_i,
    output logic [31:0] store_word_addr_o,
    output logic [31:0] store_wdata_o,
    input logic store_terminal_failure_i,
    input logic store_timeout_seen_i,
    input logic [STORE_RETRY_W-1:0] store_retry_count_i,
    input logic backend_store_status_reuse_safe_i,
    input logic store_attempt_idle_i,
    input logic memory_drain_idle_i,
    // External diagnostics are consumed separately, not echoed into the
    // frontend diagnostic output; the composition owns the aggregate.
    input logic protocol_error_i,

    output logic [COMMIT_PORT_COUNT-1:0] commit_abort_o,
    output logic commit_fault_valid_o,
    input logic commit_fault_ready_i,
    output logic [COMMIT_PORT_ID_W-1:0] commit_fault_port_id_o,
    output logic [STORE_LANES-1:0] commit_fault_lane_mask_o,
    output logic [31:0] commit_fault_word_addr_o [0:STORE_LANES-1],
    output logic [31:0] commit_fault_wdata_o [0:STORE_LANES-1],
    output logic commit_fault_store_timeout_o,
    output logic [STORE_RETRY_W-1:0] commit_fault_store_retry_count_o,

    output logic store_rearm_pulse_o,
    output logic recovery_required_o,
    output logic recovery_drain_active_o,
    output logic client_admission_fenced_o,
    output logic line_service_allowed_o,
    output logic busy_o,
    output logic protocol_error_o
);
    typedef enum logic [3:0] {
        IDLE, L2_UPDATE, MISS, ACK, FAULT, ABORTED, REARM, DRAIN, HALT
    } state_t;
    state_t state_q;

    logic [COMMIT_PORT_ID_W-1:0] rr_q, active_port_q, select_port, scan_port;
    logic select_found;
    logic [STORE_LANES-1:0] captured_lane_mask_q;
    logic [31:0] captured_word_addr_q [0:STORE_LANES-1];
    logic [31:0] captured_wdata_q [0:STORE_LANES-1];
    logic [STORE_LANES-1:0] classified_lane_mask_q, miss_lane_mask_q;
    logic [STORE_LANES-1:0] classified_total, miss_total, current_slice_mask;
    logic classification_error;
    logic source_payload_match, source_hold_required, source_error;
    logic frontend_protocol_error_q;
    logic source_withdrawn_q;
    logic fault_timeout_q;
    logic [STORE_RETRY_W-1:0] fault_retry_count_q;
    logic miss_lane_found;
    logic [STORE_LANE_ID_W-1:0] miss_lane_select;
    logic [STORE_LANES-1:0] remaining_miss_lanes;

    initial begin
        if (COMMIT_PORT_COUNT < 1 || STORE_LANES < 1 || SLICE_COUNT < 1)
            $fatal(1, "P32 frontend port, lane and slice counts must be positive");
        if (STORE_RETRY_W < 1)
            $fatal(1, "P32 frontend STORE_RETRY_W must be positive");
        if (COMMIT_PORT_ID_W < ((COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT)))
            $fatal(1, "P32 frontend commit port width is insufficient");
        if (STORE_LANE_ID_W < ((STORE_LANES <= 1) ? 1 : $clog2(STORE_LANES)))
            $fatal(1, "P32 frontend store lane width is insufficient");
    end

    always_comb begin
        select_found = 1'b0;
        select_port = '0;
        scan_port = '0;
        if (state_q == IDLE && !protocol_error_i && !frontend_protocol_error_q) begin
            for (integer offset_c = 0; offset_c < COMMIT_PORT_COUNT; offset_c = offset_c + 1) begin
                scan_port = COMMIT_PORT_ID_W'((integer'(rr_q) + offset_c) % COMMIT_PORT_COUNT);
                if (!select_found && commit_valid_i[integer'(scan_port)]) begin
                    select_found = 1'b1;
                    select_port = scan_port;
                end
            end
        end
    end

    /* P24 reports a lane classification only on that slice's acceptance.
     * Each captured lane must be classified exactly once before P24 finishes. */
    always_comb begin
        classified_total = classified_lane_mask_q;
        miss_total = miss_lane_mask_q;
        current_slice_mask = '0;
        classification_error = 1'b0;
        if (state_q == L2_UPDATE) begin
            for (integer slice_c = 0; slice_c < SLICE_COUNT; slice_c = slice_c + 1) begin
                current_slice_mask = p24_slice_store_hit_mask_i[slice_c]
                    | p24_slice_store_miss_mask_i[slice_c];
                if (|(p24_slice_store_hit_mask_i[slice_c] & p24_slice_store_miss_mask_i[slice_c]))
                    classification_error = 1'b1;
                if (|(current_slice_mask & ~captured_lane_mask_q))
                    classification_error = 1'b1;
                if (|(classified_total & current_slice_mask))
                    classification_error = 1'b1;
                classified_total |= current_slice_mask;
                miss_total |= p24_slice_store_miss_mask_i[slice_c];
            end
            if (p24_commit_ready_i[0] && classified_total != captured_lane_mask_q)
                classification_error = 1'b1;
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
        source_hold_required = state_q == L2_UPDATE || state_q == MISS
            || state_q == ACK || state_q == FAULT;
        source_error = source_hold_required && !source_payload_match;
        protocol_error_o = frontend_protocol_error_q || source_error || classification_error;
    end

    always_comb begin
        miss_lane_found = 1'b0;
        miss_lane_select = '0;
        for (integer miss_c = 0; miss_c < STORE_LANES; miss_c = miss_c + 1) begin
            if (!miss_lane_found && miss_lane_mask_q[miss_c]) begin
                miss_lane_found = 1'b1;
                miss_lane_select = STORE_LANE_ID_W'(miss_c);
            end
        end
        remaining_miss_lanes = miss_lane_mask_q & ~(STORE_LANES'(1) << miss_lane_select);
    end

    assign p24_commit_valid_o[0] = rst_n && state_q == L2_UPDATE;

    always_comb begin
        p24_commit_lane_mask_o[0] = captured_lane_mask_q;
        for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
            p24_commit_word_addr_o[0][lane_c] = captured_word_addr_q[lane_c];
            p24_commit_wdata_o[0][lane_c] = captured_wdata_q[lane_c];
        end
    end

    always_comb begin
        store_valid_o = rst_n && miss_lane_found
            && (state_q == MISS || state_q == FAULT || state_q == ABORTED || state_q == REARM);
        store_word_addr_o = captured_word_addr_q[integer'(miss_lane_select)];
        store_wdata_o = captured_wdata_q[integer'(miss_lane_select)];

        commit_ready_o = '0;
        commit_abort_o = '0;
        if (rst_n && state_q == ACK && source_payload_match)
            commit_ready_o[integer'(active_port_q)] = 1'b1;
        if (rst_n && state_q == FAULT && commit_fault_ready_i && source_payload_match)
            commit_abort_o[integer'(active_port_q)] = 1'b1;

        commit_fault_valid_o = rst_n && state_q == FAULT;
        commit_fault_port_id_o = active_port_q;
        commit_fault_lane_mask_o = captured_lane_mask_q;
        for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
            commit_fault_word_addr_o[lane_c] = captured_word_addr_q[lane_c];
            commit_fault_wdata_o[lane_c] = captured_wdata_q[lane_c];
        end
        commit_fault_store_timeout_o = fault_timeout_q;
        commit_fault_store_retry_count_o = fault_retry_count_q;
    end

    /* These state-only controls are separate from downstream handshakes. */
    assign store_rearm_pulse_o = rst_n && state_q == REARM;
    assign recovery_required_o = state_q == ABORTED || state_q == REARM
        || state_q == DRAIN || state_q == HALT;
    assign recovery_drain_active_o = state_q == DRAIN;
    assign client_admission_fenced_o = !rst_n || store_terminal_failure_i
        || state_q == FAULT || state_q == ABORTED || state_q == REARM
        || state_q == DRAIN || state_q == HALT || frontend_protocol_error_q || protocol_error_i;
    // The P32 resource-order guard prevents new conflicting READ admission
    // and delays classification until prior conflicting READ/WB has drained.
    // Already admitted, independent line work therefore keeps real service
    // while STORE waits for status, fault consumption or a reuse certificate.
    assign line_service_allowed_o = rst_n && state_q != HALT;
    assign busy_o = state_q != IDLE;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            rr_q <= '0;
            active_port_q <= '0;
            captured_lane_mask_q <= '0;
            classified_lane_mask_q <= '0;
            miss_lane_mask_q <= '0;
            frontend_protocol_error_q <= 1'b0;
            source_withdrawn_q <= 1'b0;
            fault_timeout_q <= 1'b0;
            fault_retry_count_q <= '0;
            for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                captured_word_addr_q[lane_s] <= '0;
                captured_wdata_q[lane_s] <= '0;
            end
        end else begin
            if (source_error || classification_error)
                frontend_protocol_error_q <= 1'b1;

            case (state_q)
                IDLE: begin
                    source_withdrawn_q <= 1'b0;
                    fault_timeout_q <= 1'b0;
                    fault_retry_count_q <= '0;
                    if (select_found) begin
                        active_port_q <= select_port;
                        captured_lane_mask_q <= commit_lane_mask_i[integer'(select_port)];
                        classified_lane_mask_q <= '0;
                        miss_lane_mask_q <= '0;
                        for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                            captured_word_addr_q[lane_s] <= commit_word_addr_i[integer'(select_port)][lane_s];
                            captured_wdata_q[lane_s] <= commit_wdata_i[integer'(select_port)][lane_s];
                        end
                        state_q <= L2_UPDATE;
                    end
                end
                L2_UPDATE: begin
                    classified_lane_mask_q <= classified_total;
                    miss_lane_mask_q <= miss_total;
                    if (p24_commit_ready_i[0]) begin
                        if (classification_error || frontend_protocol_error_q || source_error)
                            state_q <= HALT;
                        else if (miss_total == '0)
                            state_q <= ACK;
                        else
                            state_q <= MISS;
                    end
                end
                MISS: begin
                    if (store_terminal_failure_i) begin
                        fault_timeout_q <= store_timeout_seen_i;
                        fault_retry_count_q <= store_retry_count_i;
                        state_q <= FAULT;
                    end else if (store_valid_o && store_ready_i) begin
                        miss_lane_mask_q <= remaining_miss_lanes;
                        if (remaining_miss_lanes == '0)
                            state_q <= ACK;
                    end
                end
                ACK: begin
                    if (commit_ready_o[integer'(active_port_q)]) begin
                        if (integer'(active_port_q) == COMMIT_PORT_COUNT - 1) rr_q <= '0;
                        else rr_q <= active_port_q + COMMIT_PORT_ID_W'(1);
                        state_q <= IDLE;
                    end else if (!source_payload_match) begin
                        state_q <= HALT;
                    end
                end
                FAULT: begin
                    if (commit_abort_o[integer'(active_port_q)]) begin
                        if (integer'(active_port_q) == COMMIT_PORT_COUNT - 1) rr_q <= '0;
                        else rr_q <= active_port_q + COMMIT_PORT_ID_W'(1);
                        source_withdrawn_q <= 1'b0;
                        state_q <= ABORTED;
                    end
                end
                ABORTED: begin
                    if (!commit_valid_i[integer'(active_port_q)])
                        source_withdrawn_q <= 1'b1;
                    if ((source_withdrawn_q || !commit_valid_i[integer'(active_port_q)])
                        && backend_store_status_reuse_safe_i && store_attempt_idle_i
                        && !p24_commit_router_busy_i && !protocol_error_i && !frontend_protocol_error_q)
                        state_q <= REARM;
                end
                REARM: begin
                    // The two STORE guards reset on this edge.  P24 is live.
                    miss_lane_mask_q <= '0;
                    classified_lane_mask_q <= '0;
                    state_q <= DRAIN;
                end
                DRAIN: begin
                    if (memory_drain_idle_i && !p24_commit_router_busy_i
                        && !protocol_error_i && !frontend_protocol_error_q)
                        state_q <= IDLE;
                end
                default: state_q <= HALT;
            endcase
        end
    end
endmodule
