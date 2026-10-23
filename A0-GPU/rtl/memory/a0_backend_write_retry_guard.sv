`timescale 1ns/1ps

/*
 * PROD-SEAM-P13 bounded backend write status/retry guard.
 *
 * P12 remains frozen.  This successor accepts the P12 external issue stream,
 * gives each physical write attempt an explicit retry incarnation, and only
 * synthesizes a P12 completion ACK after an exact SUCCESS status.  Retryable
 * failures reissue the exact captured address/data with a new attempt ID.
 * Exhaustion and non-retryable failure are fail-closed and never fake success.
 */
module a0_backend_write_retry_guard #(
    parameter integer READ_ID_W = 8,
    parameter integer WRITE_ID_W = 8,
    parameter integer LINE_ADDR_W = 29,
    parameter integer MAX_RETRIES = 2,
    parameter integer RETRY_INDEX_W =
        (MAX_RETRIES < 1) ? 1 : $clog2(MAX_RETRIES + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic upstream_issue_valid_i,
    output logic upstream_issue_ready_o,
    input logic upstream_issue_write_i,
    input logic [READ_ID_W-1:0] upstream_issue_read_id_i,
    input logic [WRITE_ID_W-1:0] upstream_issue_write_id_i,
    input logic [31:0] upstream_issue_word_addr_i,
    input logic [31:0] upstream_issue_wdata_i,
    input logic [LINE_ADDR_W-1:0] upstream_issue_line_addr_i,

    output logic backend_issue_valid_o,
    input logic backend_issue_ready_i,
    output logic backend_issue_write_o,
    output logic [READ_ID_W-1:0] backend_issue_read_id_o,
    output logic [WRITE_ID_W+RETRY_INDEX_W-1:0] backend_issue_write_attempt_id_o,
    output logic [31:0] backend_issue_word_addr_o,
    output logic [31:0] backend_issue_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_issue_line_addr_o,

    input logic backend_write_status_valid_i,
    input logic [WRITE_ID_W+RETRY_INDEX_W-1:0] backend_write_status_attempt_id_i,
    input logic backend_write_status_success_i,
    input logic backend_write_status_retryable_i,

    output logic upstream_write_ack_valid_o,
    output logic [WRITE_ID_W-1:0] upstream_write_ack_id_o,

    output logic write_status_protocol_error_o,
    output logic write_retry_exhausted_o,
    output logic write_terminal_failure_o,
    output logic [RETRY_INDEX_W-1:0] write_retry_count_o,
    output logic write_retry_pending_o
);
    localparam integer ATTEMPT_ID_W = WRITE_ID_W + RETRY_INDEX_W;

    logic probe_valid_q;
    logic probe_write_q;
    logic [READ_ID_W-1:0] probe_read_id_q;
    logic [WRITE_ID_W-1:0] probe_write_id_q;
    logic [31:0] probe_word_addr_q;
    logic [31:0] probe_wdata_q;
    logic [LINE_ADDR_W-1:0] probe_line_addr_q;

    logic write_started_q;
    logic attempt_live_q;
    logic [RETRY_INDEX_W-1:0] retry_count_q;
    logic retry_exhausted_q;
    logic terminal_failure_q;

    logic source_matches;
    logic [ATTEMPT_ID_W-1:0] current_attempt_id;
    logic issue_fire;
    logic read_issue_fire;
    logic write_issue_fire;
    logic exact_live_status;
    logic exact_samecycle_status;
    logic exact_status;
    logic invalid_status_encoding;
    logic exact_success;
    logic exact_retryable_failure;
    logic exact_terminal_failure;

    initial begin
        if (READ_ID_W < 1)
            $fatal(1, "PROD_SEAM_P13 READ_ID_W must be >= 1");
        if (WRITE_ID_W < 1)
            $fatal(1, "PROD_SEAM_P13 WRITE_ID_W must be >= 1");
        if (LINE_ADDR_W < 1)
            $fatal(1, "PROD_SEAM_P13 LINE_ADDR_W must be >= 1");
        if (MAX_RETRIES < 0)
            $fatal(1, "PROD_SEAM_P13 MAX_RETRIES must be >= 0");
        if ((1 << RETRY_INDEX_W) < (MAX_RETRIES + 1))
            $fatal(1, "PROD_SEAM_P13 RETRY_INDEX_W too small for MAX_RETRIES");
    end

    always_comb begin
        source_matches =
            upstream_issue_valid_i
            && upstream_issue_write_i == probe_write_q
            && upstream_issue_read_id_i == probe_read_id_q
            && upstream_issue_write_id_i == probe_write_id_q
            && upstream_issue_word_addr_i == probe_word_addr_q
            && upstream_issue_wdata_i == probe_wdata_q
            && upstream_issue_line_addr_i == probe_line_addr_q;

        current_attempt_id = {retry_count_q, probe_write_id_q};

        backend_issue_valid_o = probe_valid_q;
        if (probe_write_q)
            backend_issue_valid_o = probe_valid_q
                && !attempt_live_q
                && !retry_exhausted_q
                && !terminal_failure_q;
        backend_issue_write_o = probe_write_q;
        backend_issue_read_id_o = probe_read_id_q;
        backend_issue_write_attempt_id_o = probe_write_q ? current_attempt_id : '0;
        backend_issue_word_addr_o = probe_word_addr_q;
        backend_issue_wdata_o = probe_wdata_q;
        backend_issue_line_addr_o = probe_line_addr_q;

        issue_fire = backend_issue_valid_o && backend_issue_ready_i;
        read_issue_fire = issue_fire && !probe_write_q;
        write_issue_fire = issue_fire && probe_write_q;

        exact_live_status = backend_write_status_valid_i
            && probe_valid_q
            && probe_write_q
            && attempt_live_q
            && backend_write_status_attempt_id_i == current_attempt_id;
        exact_samecycle_status = backend_write_status_valid_i
            && write_issue_fire
            && backend_write_status_attempt_id_i == current_attempt_id;
        exact_status = exact_live_status || exact_samecycle_status;
        invalid_status_encoding = backend_write_status_valid_i
            && backend_write_status_success_i
            && backend_write_status_retryable_i;

        exact_success = exact_status
            && backend_write_status_success_i
            && !backend_write_status_retryable_i;
        exact_retryable_failure = exact_status
            && !backend_write_status_success_i
            && backend_write_status_retryable_i;
        exact_terminal_failure = exact_status
            && !backend_write_status_success_i
            && !backend_write_status_retryable_i;

        upstream_issue_ready_o = 1'b0;
        if (read_issue_fire)
            upstream_issue_ready_o = 1'b1;
        else if (write_issue_fire && !write_started_q)
            upstream_issue_ready_o = 1'b1;

        upstream_write_ack_valid_o = exact_success;
        upstream_write_ack_id_o = probe_write_id_q;

        write_status_protocol_error_o = backend_write_status_valid_i
            && (!exact_status || invalid_status_encoding);
        write_retry_exhausted_o = retry_exhausted_q;
        write_terminal_failure_o = terminal_failure_q;
        write_retry_count_o = retry_count_q;
        write_retry_pending_o = probe_valid_q && probe_write_q
            && write_started_q && !attempt_live_q
            && !retry_exhausted_q && !terminal_failure_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            probe_valid_q <= 1'b0;
            probe_write_q <= 1'b0;
            probe_read_id_q <= '0;
            probe_write_id_q <= '0;
            probe_word_addr_q <= '0;
            probe_wdata_q <= '0;
            probe_line_addr_q <= '0;
            write_started_q <= 1'b0;
            attempt_live_q <= 1'b0;
            retry_count_q <= '0;
            retry_exhausted_q <= 1'b0;
            terminal_failure_q <= 1'b0;
        end else begin
            if (!probe_valid_q && upstream_issue_valid_i) begin
                probe_valid_q <= 1'b1;
                probe_write_q <= upstream_issue_write_i;
                probe_read_id_q <= upstream_issue_read_id_i;
                probe_write_id_q <= upstream_issue_write_id_i;
                probe_word_addr_q <= upstream_issue_word_addr_i;
                probe_wdata_q <= upstream_issue_wdata_i;
                probe_line_addr_q <= upstream_issue_line_addr_i;
                write_started_q <= 1'b0;
                attempt_live_q <= 1'b0;
                retry_count_q <= '0;
                retry_exhausted_q <= 1'b0;
                terminal_failure_q <= 1'b0;
            end

            if (probe_valid_q && !write_started_q && !source_matches)
                $fatal(1, "PROD_SEAM_P13_UPSTREAM_COMMAND_CHANGED_BEFORE_FIRST_ISSUE");

            if (read_issue_fire)
                probe_valid_q <= 1'b0;

            if (write_issue_fire) begin
                write_started_q <= 1'b1;
                if (!exact_samecycle_status)
                    attempt_live_q <= 1'b1;
            end

            if (exact_success) begin
                probe_valid_q <= 1'b0;
                attempt_live_q <= 1'b0;
                write_started_q <= 1'b0;
            end else if (exact_retryable_failure) begin
                attempt_live_q <= 1'b0;
                if (retry_count_q != RETRY_INDEX_W'(MAX_RETRIES)) begin
                    retry_count_q <= retry_count_q + RETRY_INDEX_W'(1);
                end else begin
                    retry_exhausted_q <= 1'b1;
                end
            end else if (exact_terminal_failure) begin
                attempt_live_q <= 1'b0;
                terminal_failure_q <= 1'b1;
            end
        end
    end
endmodule
