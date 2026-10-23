`timescale 1ns/1ps

/*
 * PROD-SEAM-P25 bounded no-write-allocate store-miss visibility successor.
 *
 * Frozen P24 performs resident dirty-L2 updates.  P25 wraps that commit seam,
 * records exact lanes reported as L2 store misses, and mirrors only those miss
 * lanes onto the same external visibility-domain command boundary used by P23
 * refill reads / durable writebacks.  The upstream P7-shaped commit is not
 * acknowledged until P24 has completed and every miss-lane word write has
 * been accepted.  Accepted STORE_WORD is the bounded visibility point.
 *
 * This is not a physical VRAM controller and does not claim atomic RMW,
 * ownership/snoops, atomics, or complete global memory ordering.
 */
module a0_production_store_commit_write_miss_visibility_subsystem #(
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
    parameter integer COMMIT_PORT_ID_W = (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer STORE_LANE_ID_W = (STORE_LANES <= 1) ? 1 : $clog2(STORE_LANES)
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
    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o,
    output logic protocol_error_o
);
    localparam logic [1:0] BACKEND_KIND_READ       = 2'b00;
    localparam logic [1:0] BACKEND_KIND_WRITEBACK  = 2'b01;
    localparam logic [1:0] BACKEND_KIND_STORE_WORD = 2'b10;

    typedef enum logic [1:0] {IDLE, L2_UPDATE, MISS_DRAIN, ACK} commit_state_t;
    commit_state_t state_q;

    logic [COMMIT_PORT_ID_W-1:0] rr_q, active_port_q, select_port;
    logic select_found;
    logic [STORE_LANES-1:0] captured_lane_mask_q;
    logic [31:0] captured_word_addr_q [0:STORE_LANES-1];
    logic [31:0] captured_wdata_q [0:STORE_LANES-1];
    logic [STORE_LANES-1:0] miss_lane_mask_q;
    logic [STORE_LANES-1:0] miss_union;
    logic [STORE_LANES-1:0] miss_total;
    logic miss_lane_found;
    logic [STORE_LANE_ID_W-1:0] miss_lane_select;
    logic source_protocol_error;

    logic [0:0] p24_commit_valid, p24_commit_ready;
    logic [STORE_LANES-1:0] p24_commit_lane_mask [0:0];
    logic [31:0] p24_commit_word_addr [0:0][0:STORE_LANES-1];
    logic [31:0] p24_commit_wdata [0:0][0:STORE_LANES-1];
    logic [STORE_LANES-1:0] p24_store_hit_mask [0:SLICE_COUNT-1];
    logic [STORE_LANES-1:0] p24_store_miss_mask [0:SLICE_COUNT-1];
    logic p24_commit_router_busy;
    logic p24_protocol_error;
    logic p24_store_classification_error;

    logic p24_backend_valid, p24_backend_ready, p24_backend_write;
    logic [BACKEND_READ_TAG_W-1:0] p24_backend_read_tag;
    logic [BACKEND_ATTEMPT_ID_W-1:0] p24_backend_wb_attempt_id;
    logic [LINE_ADDR_W-1:0] p24_backend_line_addr;
    logic [31:0] p24_backend_data [0:LINE_WORDS-1];

    integer scan_offset;
    logic [COMMIT_PORT_ID_W-1:0] scan_port;
    integer capture_lane;
    integer miss_slice;
    integer miss_scan;
    integer data_word;

    initial begin
        if (COMMIT_PORT_COUNT < 1) $fatal(1, "P25 COMMIT_PORT_COUNT must be >=1");
        if (STORE_LANES < 1) $fatal(1, "P25 STORE_LANES must be >=1");
    end

    always_comb begin
        select_found = 1'b0;
        select_port = '0;
        scan_port = '0;
        if (state_q == IDLE) begin
            for (scan_offset = 0; scan_offset < COMMIT_PORT_COUNT; scan_offset = scan_offset + 1) begin
                scan_port = COMMIT_PORT_ID_W'((integer'(rr_q)+scan_offset)%COMMIT_PORT_COUNT);
                if (!select_found && commit_valid_i[integer'(scan_port)]) begin
                    select_found = 1'b1;
                    select_port = scan_port;
                end
            end
        end
    end

    always_comb begin
        p24_commit_valid = '0;
        p24_commit_lane_mask[0] = captured_lane_mask_q;
        for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
            p24_commit_word_addr[0][lane] = captured_word_addr_q[lane];
            p24_commit_wdata[0][lane] = captured_wdata_q[lane];
        end
        if (state_q == L2_UPDATE) p24_commit_valid[0] = 1'b1;

        miss_union = '0;
        p24_store_classification_error = 1'b0;
        for (miss_slice = 0; miss_slice < SLICE_COUNT; miss_slice = miss_slice + 1) begin
            miss_union |= p24_store_miss_mask[miss_slice];
            if (|(p24_store_hit_mask[miss_slice] & p24_store_miss_mask[miss_slice]))
                p24_store_classification_error = 1'b1;
            if (|((p24_store_hit_mask[miss_slice] | p24_store_miss_mask[miss_slice]) & ~captured_lane_mask_q))
                p24_store_classification_error = 1'b1;
        end
        miss_total = miss_lane_mask_q | miss_union;

        miss_lane_found = 1'b0;
        miss_lane_select = '0;
        for (miss_scan = 0; miss_scan < STORE_LANES; miss_scan = miss_scan + 1) begin
            if (!miss_lane_found && miss_lane_mask_q[miss_scan]) begin
                miss_lane_found = 1'b1;
                miss_lane_select = STORE_LANE_ID_W'(miss_scan);
            end
        end
    end

    always_comb begin
        commit_ready_o = '0;
        if (state_q == ACK)
            commit_ready_o[integer'(active_port_q)] = 1'b1;

        backend_cmd_valid_o = 1'b0;
        backend_cmd_kind_o = BACKEND_KIND_READ;
        backend_cmd_read_tag_o = '0;
        backend_cmd_wb_attempt_id_o = '0;
        backend_cmd_line_addr_o = '0;
        backend_cmd_store_word_addr_o = '0;
        backend_cmd_store_wdata_o = '0;
        for (data_word = 0; data_word < LINE_WORDS; data_word = data_word + 1)
            backend_cmd_data_o[data_word] = '0;

        p24_backend_ready = 1'b0;
        if (state_q == MISS_DRAIN) begin
            backend_cmd_valid_o = miss_lane_found;
            backend_cmd_kind_o = BACKEND_KIND_STORE_WORD;
            backend_cmd_store_word_addr_o = captured_word_addr_q[integer'(miss_lane_select)];
            backend_cmd_store_wdata_o = captured_wdata_q[integer'(miss_lane_select)];
        end else begin
            backend_cmd_valid_o = p24_backend_valid;
            backend_cmd_kind_o = p24_backend_write ? BACKEND_KIND_WRITEBACK : BACKEND_KIND_READ;
            backend_cmd_read_tag_o = p24_backend_read_tag;
            backend_cmd_wb_attempt_id_o = p24_backend_wb_attempt_id;
            backend_cmd_line_addr_o = p24_backend_line_addr;
            for (data_word = 0; data_word < LINE_WORDS; data_word = data_word + 1)
                backend_cmd_data_o[data_word] = p24_backend_data[data_word];
            p24_backend_ready = backend_cmd_ready_i;
        end

        source_protocol_error = (state_q != IDLE)
            && !commit_valid_i[integer'(active_port_q)];
        commit_visibility_busy_o = (state_q != IDLE) || p24_commit_router_busy;
        protocol_error_o = p24_protocol_error || source_protocol_error || p24_store_classification_error;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            rr_q <= '0;
            active_port_q <= '0;
            captured_lane_mask_q <= '0;
            miss_lane_mask_q <= '0;
            for (capture_lane = 0; capture_lane < STORE_LANES; capture_lane = capture_lane + 1) begin
                captured_word_addr_q[capture_lane] <= '0;
                captured_wdata_q[capture_lane] <= '0;
            end
        end else begin
            case (state_q)
                IDLE: begin
                    miss_lane_mask_q <= '0;
                    if (select_found) begin
                        active_port_q <= select_port;
                        captured_lane_mask_q <= commit_lane_mask_i[integer'(select_port)];
                        for (capture_lane = 0; capture_lane < STORE_LANES; capture_lane = capture_lane + 1) begin
                            captured_word_addr_q[capture_lane] <= commit_word_addr_i[integer'(select_port)][capture_lane];
                            captured_wdata_q[capture_lane] <= commit_wdata_i[integer'(select_port)][capture_lane];
                        end
                        state_q <= L2_UPDATE;
                    end
                end
                L2_UPDATE: begin
                    miss_lane_mask_q <= miss_total;
                    if (p24_commit_ready[0]) begin
                        if (miss_total == '0) state_q <= ACK;
                        else state_q <= MISS_DRAIN;
                    end
                end
                MISS_DRAIN: begin
                    if (backend_cmd_valid_o && backend_cmd_ready_i) begin
                        miss_lane_mask_q[integer'(miss_lane_select)] <= 1'b0;
                        if ((miss_lane_mask_q & ~(STORE_LANES'(1) << miss_lane_select)) == '0)
                            state_q <= ACK;
                    end
                end
                ACK: begin
                    if (commit_valid_i[integer'(active_port_q)]
                        && commit_ready_o[integer'(active_port_q)]) begin
                        if (integer'(active_port_q) == COMMIT_PORT_COUNT-1) rr_q <= '0;
                        else rr_q <= active_port_q + COMMIT_PORT_ID_W'(1);
                        state_q <= IDLE;
                    end
                end
                default: state_q <= IDLE;
            endcase
        end
    end

    a0_production_store_commit_dirty_l2_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING), .COMMIT_PORT_COUNT(1),
        .STORE_LANES(STORE_LANES), .SLICE_COUNT(SLICE_COUNT), .LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE), .WRITE_ID_W(WRITE_ID_W),
        .MAX_WB_RETRIES(MAX_WB_RETRIES), .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) u_p24 (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i), .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i), .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o), .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o), .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .commit_valid_i(p24_commit_valid), .commit_ready_o(p24_commit_ready),
        .commit_lane_mask_i(p24_commit_lane_mask), .commit_word_addr_i(p24_commit_word_addr),
        .commit_wdata_i(p24_commit_wdata),
        .backend_cmd_valid_o(p24_backend_valid), .backend_cmd_ready_i(p24_backend_ready),
        .backend_cmd_write_o(p24_backend_write), .backend_cmd_read_tag_o(p24_backend_read_tag),
        .backend_cmd_wb_attempt_id_o(p24_backend_wb_attempt_id),
        .backend_cmd_line_addr_o(p24_backend_line_addr), .backend_cmd_data_o(p24_backend_data),
        .backend_read_resp_valid_i(backend_read_resp_valid_i), .backend_read_resp_tag_i(backend_read_resp_tag_i),
        .backend_read_resp_line_addr_i(backend_read_resp_line_addr_i), .backend_read_resp_fault_i(backend_read_resp_fault_i),
        .backend_read_resp_data_i(backend_read_resp_data_i),
        .backend_wb_status_valid_i(backend_wb_status_valid_i), .backend_wb_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_wb_status_success_i(backend_wb_status_success_i), .backend_wb_status_retryable_i(backend_wb_status_retryable_i),
        .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),
        .backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .slice_store_hit_mask_o(p24_store_hit_mask), .slice_store_miss_mask_o(p24_store_miss_mask),
        .dirty_present_o(dirty_present_o), .wb_busy_o(wb_busy_o), .wb_retry_count_o(wb_retry_count_o),
        .wb_terminal_failure_o(wb_terminal_failure_o), .recovery_active_o(recovery_active_o),
        .recovery_complete_pulse_o(recovery_complete_pulse_o), .wb_pending_count_o(wb_pending_count_o),
        .wb_active_count_o(wb_active_count_o), .commit_router_busy_o(p24_commit_router_busy),
        .line_resp_tag_error_o(line_resp_tag_error_o), .line_resp_overflow_o(line_resp_overflow_o),
        .protocol_error_o(p24_protocol_error)
    );
endmodule
