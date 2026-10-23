`timescale 1ns/1ps

/*
 * PROD-SEAM-P8 bounded unified store-commit / line-refill backend adapter.
 *
 * Successful P7 visibility commits are decomposed into lane-qualified word
 * writes on one unified backend command stream. Shared-L2 refill reads use
 * the same command stream and carry an explicit {slice, network-tag} identity.
 *
 * A commit source is acknowledged only when its final active store beat is
 * accepted by the backend. Refill requests conflicting with any pending
 * commit are held; non-conflicting reads may interleave fairly with an active
 * multi-beat commit. This is a bounded visibility/serialization seam, not a
 * dirty/writeback/ownership protocol or a VRAM controller.
 */
module a0_store_commit_line_backend_adapter #(
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer LINE_PORT_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer NETWORK_TAG_W = 4,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer COMMIT_PORT_ID_W =
        (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer STORE_LANE_ID_W =
        (STORE_LANES <= 1) ? 1 : $clog2(STORE_LANES),
    parameter integer STORE_LANE_CURSOR_W =
        (STORE_LANES <= 1) ? 1 : $clog2(STORE_LANES + 1),
    parameter integer LINE_PORT_ID_W =
        (LINE_PORT_COUNT <= 1) ? 1 : $clog2(LINE_PORT_COUNT),
    parameter integer BACKEND_READ_TAG_W =
        LINE_PORT_ID_W + NETWORK_TAG_W
) (
    input logic clk,
    input logic rst_n,

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    output logic [COMMIT_PORT_COUNT-1:0] commit_ready_o,
    input logic [STORE_LANES-1:0]
        commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0]
        commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0]
        commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    input logic [LINE_PORT_COUNT-1:0] line_req_valid_i,
    output logic [LINE_PORT_COUNT-1:0] line_req_ready_o,
    input logic [NETWORK_TAG_W-1:0]
        line_req_network_tag_i [0:LINE_PORT_COUNT-1],
    input logic [LINE_ADDR_W-1:0]
        line_req_line_addr_i [0:LINE_PORT_COUNT-1],

    output logic [LINE_PORT_COUNT-1:0] line_resp_valid_o,
    output logic [NETWORK_TAG_W-1:0]
        line_resp_network_tag_o [0:LINE_PORT_COUNT-1],
    output logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_o [0:LINE_PORT_COUNT-1],
    output logic line_resp_fault_o [0:LINE_PORT_COUNT-1],
    output logic [31:0]
        line_resp_data_o [0:LINE_PORT_COUNT-1][0:LINE_WORDS-1],
    output logic backend_resp_protocol_error_o,

    /* One ordered external visibility-domain command stream. */
    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [31:0] backend_cmd_word_addr_o,
    output logic [31:0] backend_cmd_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,

    /* Read responses only; accepted writes are the visibility point. */
    input logic backend_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_resp_read_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_resp_line_addr_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_data_i [0:LINE_WORDS-1]
);
    logic commit_active_q;
    logic [COMMIT_PORT_ID_W-1:0] commit_port_q;
    logic [COMMIT_PORT_ID_W-1:0] commit_rr_q;
    logic [STORE_LANE_CURSOR_W-1:0] commit_lane_cursor_q;
    logic [STORE_LANES-1:0] active_commit_lane_mask_q;
    logic [31:0] active_commit_word_addr_q [0:STORE_LANES-1];
    logic [31:0] active_commit_wdata_q [0:STORE_LANES-1];

    logic commit_select_found;
    logic [COMMIT_PORT_ID_W-1:0] commit_select_port;
    logic commit_select_duplicate_word;
    logic commit_select_zero_mask;

    logic store_beat_valid;
    logic [STORE_LANE_ID_W-1:0] store_beat_lane;
    logic store_beat_last;

    /* One registered request slot per line port breaks ready/valid combinational
     * loops at the P6/shared-L2 boundary and provides explicit finite
     * backpressure. A slot may be consumed and replaced in the same cycle. */
    logic [LINE_PORT_COUNT-1:0] line_pending_q;
    logic [NETWORK_TAG_W-1:0]
        line_pending_tag_q [0:LINE_PORT_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        line_pending_addr_q [0:LINE_PORT_COUNT-1];

    logic [LINE_PORT_COUNT-1:0] line_blocked_by_commit;
    logic line_select_found;
    logic [LINE_PORT_ID_W-1:0] line_select_port;
    logic [LINE_PORT_ID_W-1:0] line_rr_q;

    logic prefer_line_q;
    logic choose_store;
    logic choose_line;
    logic command_fire;
    logic response_slice_valid;
    logic [LINE_PORT_ID_W-1:0] response_slice;

    initial begin
        if (COMMIT_PORT_COUNT < 1)
            $fatal(1, "PROD_SEAM_P8 COMMIT_PORT_COUNT must be >= 1");
        if (STORE_LANES < 1)
            $fatal(1, "PROD_SEAM_P8 STORE_LANES must be >= 1");
        if (LINE_PORT_COUNT < 1)
            $fatal(1, "PROD_SEAM_P8 LINE_PORT_COUNT must be >= 1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "PROD_SEAM_P8 LINE_WORDS must be a power of two");
    end

    always_comb begin
        commit_select_found = 1'b0;
        commit_select_port = '0;
        for (integer off = 0; off < COMMIT_PORT_COUNT; off = off + 1) begin
            integer scan_port;
            scan_port = integer'(commit_rr_q) + off;
            if (scan_port >= COMMIT_PORT_COUNT)
                scan_port = scan_port - COMMIT_PORT_COUNT;
            if (!commit_select_found && commit_valid_i[scan_port]) begin
                commit_select_found = 1'b1;
                commit_select_port = COMMIT_PORT_ID_W'(scan_port);
            end
        end

        commit_select_zero_mask = 1'b0;
        commit_select_duplicate_word = 1'b0;
        if (commit_select_found) begin
            commit_select_zero_mask =
                !(|commit_lane_mask_i[integer'(commit_select_port)]);
            for (integer lane_a = 0; lane_a < STORE_LANES; lane_a = lane_a + 1) begin
                for (integer lane_b = lane_a + 1;
                     lane_b < STORE_LANES; lane_b = lane_b + 1) begin
                    if (commit_lane_mask_i[integer'(commit_select_port)][lane_a]
                        && commit_lane_mask_i[integer'(commit_select_port)][lane_b]
                        && commit_word_addr_i[integer'(commit_select_port)][lane_a]
                            == commit_word_addr_i[integer'(commit_select_port)][lane_b])
                        commit_select_duplicate_word = 1'b1;
                end
            end
        end

        store_beat_valid = 1'b0;
        store_beat_lane = '0;
        store_beat_last = 1'b0;
        if (commit_active_q) begin
            for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (!store_beat_valid
                    && lane >= integer'(commit_lane_cursor_q)
                    && active_commit_lane_mask_q[lane]) begin
                    store_beat_valid = 1'b1;
                    store_beat_lane = STORE_LANE_ID_W'(lane);
                end
            end
            if (store_beat_valid) begin
                store_beat_last = 1'b1;
                for (integer later_lane = 0;
                     later_lane < STORE_LANES; later_lane = later_lane + 1) begin
                    if (later_lane > integer'(store_beat_lane)
                        && active_commit_lane_mask_q[later_lane])
                        store_beat_last = 1'b0;
                end
            end
        end

        line_blocked_by_commit = '0;
        for (integer line_port = 0;
             line_port < LINE_PORT_COUNT; line_port = line_port + 1) begin
            for (integer commit_port = 0;
                 commit_port < COMMIT_PORT_COUNT; commit_port = commit_port + 1) begin
                if (commit_valid_i[commit_port]) begin
                    for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                        if (commit_lane_mask_i[commit_port][lane]
                            && commit_word_addr_i[commit_port][lane][31:WORD_SELECT_W]
                                == line_pending_addr_q[line_port])
                            line_blocked_by_commit[line_port] = 1'b1;
                    end
                end
            end
        end

        line_select_found = 1'b0;
        line_select_port = '0;
        for (integer off = 0; off < LINE_PORT_COUNT; off = off + 1) begin
            integer scan_line;
            scan_line = integer'(line_rr_q) + off;
            if (scan_line >= LINE_PORT_COUNT)
                scan_line = scan_line - LINE_PORT_COUNT;
            if (!line_select_found
                && line_pending_q[scan_line]
                && !line_blocked_by_commit[scan_line]) begin
                line_select_found = 1'b1;
                line_select_port = LINE_PORT_ID_W'(scan_line);
            end
        end

        choose_store = 1'b0;
        choose_line = 1'b0;
        if (store_beat_valid && line_select_found) begin
            if (prefer_line_q)
                choose_line = 1'b1;
            else
                choose_store = 1'b1;
        end else if (store_beat_valid) begin
            choose_store = 1'b1;
        end else if (line_select_found) begin
            choose_line = 1'b1;
        end

        backend_cmd_valid_o = choose_store || choose_line;
        backend_cmd_write_o = choose_store;
        backend_cmd_read_tag_o = '0;
        backend_cmd_word_addr_o = '0;
        backend_cmd_wdata_o = '0;
        backend_cmd_line_addr_o = '0;

        if (choose_store) begin
            backend_cmd_word_addr_o =
                active_commit_word_addr_q[integer'(store_beat_lane)];
            backend_cmd_wdata_o =
                active_commit_wdata_q[integer'(store_beat_lane)];
            backend_cmd_line_addr_o =
                active_commit_word_addr_q[integer'(store_beat_lane)][31:WORD_SELECT_W];
        end else if (choose_line) begin
            backend_cmd_read_tag_o = {
                LINE_PORT_ID_W'(line_select_port),
                line_pending_tag_q[integer'(line_select_port)]
            };
            backend_cmd_line_addr_o =
                line_pending_addr_q[integer'(line_select_port)];
        end

        command_fire = backend_cmd_valid_o && backend_cmd_ready_i;

        commit_ready_o = '0;
        if (choose_store && backend_cmd_ready_i && store_beat_last)
            commit_ready_o[integer'(commit_port_q)] = 1'b1;

        for (integer port = 0; port < LINE_PORT_COUNT; port = port + 1) begin
            line_req_ready_o[port] = !line_pending_q[port];
            if (choose_line && backend_cmd_ready_i
                && integer'(line_select_port) == port)
                line_req_ready_o[port] = 1'b1;
        end

        line_resp_valid_o = '0;
        for (integer port = 0; port < LINE_PORT_COUNT; port = port + 1) begin
            line_resp_network_tag_o[port] = '0;
            line_resp_line_addr_o[port] = '0;
            line_resp_fault_o[port] = 1'b0;
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                line_resp_data_o[port][word] = '0;
        end

        response_slice = backend_resp_read_tag_i[
            BACKEND_READ_TAG_W-1 -: LINE_PORT_ID_W
        ];
        response_slice_valid =
            integer'(response_slice) < LINE_PORT_COUNT;
        backend_resp_protocol_error_o =
            backend_resp_valid_i && !response_slice_valid;

        if (backend_resp_valid_i && response_slice_valid) begin
            line_resp_valid_o[integer'(response_slice)] = 1'b1;
            line_resp_network_tag_o[integer'(response_slice)] =
                backend_resp_read_tag_i[NETWORK_TAG_W-1:0];
            line_resp_line_addr_o[integer'(response_slice)] =
                backend_resp_line_addr_i;
            line_resp_fault_o[integer'(response_slice)] =
                backend_resp_fault_i;
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                line_resp_data_o[integer'(response_slice)][word] =
                    backend_resp_data_i[word];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            commit_active_q <= 1'b0;
            commit_port_q <= '0;
            commit_rr_q <= '0;
            commit_lane_cursor_q <= '0;
            active_commit_lane_mask_q <= '0;
            line_rr_q <= '0;
            prefer_line_q <= 1'b0;
            line_pending_q <= '0;
            for (integer port = 0; port < LINE_PORT_COUNT; port = port + 1) begin
                line_pending_tag_q[port] <= '0;
                line_pending_addr_q[port] <= '0;
            end
            for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                active_commit_word_addr_q[lane] <= '0;
                active_commit_wdata_q[lane] <= '0;
            end
        end else begin
            for (integer port = 0; port < LINE_PORT_COUNT; port = port + 1) begin
                if (line_req_ready_o[port]) begin
                    line_pending_q[port] <= line_req_valid_i[port];
                    if (line_req_valid_i[port]) begin
                        line_pending_tag_q[port] <= line_req_network_tag_i[port];
                        line_pending_addr_q[port] <= line_req_line_addr_i[port];
                    end
                end
            end

            if (!commit_active_q && commit_select_found) begin
                if (commit_select_zero_mask)
                    $fatal(1, "PROD_SEAM_P8_ZERO_LANE_COMMIT");
                if (commit_select_duplicate_word)
                    $fatal(1, "PROD_SEAM_P8_DUPLICATE_STORE_WORD_UNFROZEN");
                commit_active_q <= 1'b1;
                commit_port_q <= commit_select_port;
                commit_lane_cursor_q <= '0;
                active_commit_lane_mask_q <=
                    commit_lane_mask_i[integer'(commit_select_port)];
                for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                    active_commit_word_addr_q[lane] <=
                        commit_word_addr_i[integer'(commit_select_port)][lane];
                    active_commit_wdata_q[lane] <=
                        commit_wdata_i[integer'(commit_select_port)][lane];
                end
            end

            if (commit_active_q
                && !commit_valid_i[integer'(commit_port_q)])
                $fatal(1, "PROD_SEAM_P8_COMMIT_SOURCE_DROPPED_VALID");

            if (commit_active_q && !store_beat_valid)
                $fatal(1, "PROD_SEAM_P8_COMMIT_PAYLOAD_CHANGED");

            if (command_fire && choose_store) begin
                prefer_line_q <= 1'b1;
                if (store_beat_last) begin
                    commit_active_q <= 1'b0;
                    commit_lane_cursor_q <= '0;
                    if (integer'(commit_port_q) == COMMIT_PORT_COUNT - 1)
                        commit_rr_q <= '0;
                    else
                        commit_rr_q <= commit_port_q + COMMIT_PORT_ID_W'(1);
                end else begin
                    commit_lane_cursor_q <= STORE_LANE_CURSOR_W'(
                        integer'(store_beat_lane) + 1
                    );
                end
            end

            if (command_fire && choose_line) begin
                prefer_line_q <= 1'b0;
                if (integer'(line_select_port) == LINE_PORT_COUNT - 1)
                    line_rr_q <= '0;
                else
                    line_rr_q <= line_select_port + LINE_PORT_ID_W'(1);
            end
        end
    end
endmodule
