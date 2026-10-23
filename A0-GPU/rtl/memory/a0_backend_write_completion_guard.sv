`timescale 1ns/1ps

/*
 * PROD-SEAM-P12 bounded backend write-completion guard.
 *
 * The predecessor command is snapshotted without handshaking. Reads are
 * acknowledged upstream only when the exact read is externally issued. Writes
 * are issued exactly once with a bounded write incarnation ID, but predecessor
 * ready remains low until the exact external completion ACK arrives. Thus the
 * frozen P8-P11 visibility point moves from write issue to write completion
 * without changing predecessor RTL.
 */
module a0_backend_write_completion_guard #(
    parameter integer READ_ID_W = 8,
    parameter integer WRITE_ID_W = 8,
    parameter integer LINE_ADDR_W = 29
) (
    input logic clk,
    input logic rst_n,

    input logic upstream_cmd_valid_i,
    output logic upstream_cmd_ready_o,
    input logic upstream_cmd_write_i,
    input logic [READ_ID_W-1:0] upstream_cmd_read_id_i,
    input logic [31:0] upstream_cmd_word_addr_i,
    input logic [31:0] upstream_cmd_wdata_i,
    input logic [LINE_ADDR_W-1:0] upstream_cmd_line_addr_i,

    output logic backend_issue_valid_o,
    input logic backend_issue_ready_i,
    output logic backend_issue_write_o,
    output logic [READ_ID_W-1:0] backend_issue_read_id_o,
    output logic [WRITE_ID_W-1:0] backend_issue_write_id_o,
    output logic [31:0] backend_issue_word_addr_o,
    output logic [31:0] backend_issue_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_issue_line_addr_o,

    input logic backend_write_ack_valid_i,
    input logic [WRITE_ID_W-1:0] backend_write_ack_id_i,
    input logic backend_write_reuse_safe_i,

    output logic write_ack_protocol_error_o,
    output logic write_wrap_block_o,
    output logic [WRITE_ID_W-1:0] next_write_id_o,
    output logic write_pending_o,
    output logic write_issued_o
);
    logic probe_valid_q;
    logic probe_write_q;
    logic [READ_ID_W-1:0] probe_read_id_q;
    logic [31:0] probe_word_addr_q;
    logic [31:0] probe_wdata_q;
    logic [LINE_ADDR_W-1:0] probe_line_addr_q;

    logic write_issued_q;
    logic [WRITE_ID_W-1:0] live_write_id_q;
    logic [WRITE_ID_W-1:0] next_write_id_q;
    logic write_wrap_block_q;

    logic probe_source_matches;
    logic issue_fire;
    logic read_issue_fire;
    logic write_issue_fire;
    logic exact_live_ack;
    logic exact_samecycle_ack;
    logic exact_write_ack;

    initial begin
        if (READ_ID_W < 1)
            $fatal(1, "PROD_SEAM_P12 READ_ID_W must be >= 1");
        if (WRITE_ID_W < 1)
            $fatal(1, "PROD_SEAM_P12 WRITE_ID_W must be >= 1");
        if (LINE_ADDR_W < 1)
            $fatal(1, "PROD_SEAM_P12 LINE_ADDR_W must be >= 1");
    end

    always_comb begin
        probe_source_matches =
            upstream_cmd_valid_i
            && upstream_cmd_write_i == probe_write_q
            && upstream_cmd_read_id_i == probe_read_id_q
            && upstream_cmd_word_addr_i == probe_word_addr_q
            && upstream_cmd_wdata_i == probe_wdata_q
            && upstream_cmd_line_addr_i == probe_line_addr_q;

        backend_issue_valid_o = probe_valid_q
            && (!probe_write_q || (!write_issued_q && !write_wrap_block_q));
        backend_issue_write_o = probe_write_q;
        backend_issue_read_id_o = probe_read_id_q;
        backend_issue_write_id_o = probe_write_q ? next_write_id_q : '0;
        backend_issue_word_addr_o = probe_word_addr_q;
        backend_issue_wdata_o = probe_wdata_q;
        backend_issue_line_addr_o = probe_line_addr_q;

        issue_fire = backend_issue_valid_o && backend_issue_ready_i;
        read_issue_fire = issue_fire && !probe_write_q;
        write_issue_fire = issue_fire && probe_write_q;

        exact_live_ack = backend_write_ack_valid_i
            && write_issued_q
            && backend_write_ack_id_i == live_write_id_q;
        exact_samecycle_ack = backend_write_ack_valid_i
            && write_issue_fire
            && backend_write_ack_id_i == next_write_id_q;
        exact_write_ack = exact_live_ack || exact_samecycle_ack;

        upstream_cmd_ready_o = 1'b0;
        if (read_issue_fire)
            upstream_cmd_ready_o = 1'b1;
        else if (probe_valid_q && probe_write_q && exact_write_ack)
            upstream_cmd_ready_o = 1'b1;

        write_ack_protocol_error_o =
            backend_write_ack_valid_i && !exact_write_ack;
        write_wrap_block_o = write_wrap_block_q;
        next_write_id_o = next_write_id_q;
        write_pending_o = probe_valid_q && probe_write_q;
        write_issued_o = write_issued_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            probe_valid_q <= 1'b0;
            probe_write_q <= 1'b0;
            probe_read_id_q <= '0;
            probe_word_addr_q <= '0;
            probe_wdata_q <= '0;
            probe_line_addr_q <= '0;
            write_issued_q <= 1'b0;
            live_write_id_q <= '0;
            next_write_id_q <= '0;
            write_wrap_block_q <= 1'b0;
        end else begin
            if (!probe_valid_q && upstream_cmd_valid_i) begin
                probe_valid_q <= 1'b1;
                probe_write_q <= upstream_cmd_write_i;
                probe_read_id_q <= upstream_cmd_read_id_i;
                probe_word_addr_q <= upstream_cmd_word_addr_i;
                probe_wdata_q <= upstream_cmd_wdata_i;
                probe_line_addr_q <= upstream_cmd_line_addr_i;
            end

            if (probe_valid_q && !probe_source_matches)
                $fatal(1, "PROD_SEAM_P12_UPSTREAM_COMMAND_CHANGED_BEFORE_COMPLETION");

            if (backend_write_reuse_safe_i && (write_issued_q || write_issue_fire))
                $fatal(1, "PROD_SEAM_P12_REUSE_SAFE_WITH_LIVE_WRITE");

            if (backend_write_reuse_safe_i && !write_issued_q && !write_issue_fire)
                write_wrap_block_q <= 1'b0;

            if (read_issue_fire)
                probe_valid_q <= 1'b0;

            if (write_issue_fire) begin
                if (exact_samecycle_ack) begin
                    probe_valid_q <= 1'b0;
                    write_issued_q <= 1'b0;
                end else begin
                    write_issued_q <= 1'b1;
                    live_write_id_q <= next_write_id_q;
                end

                if (&next_write_id_q) begin
                    next_write_id_q <= '0;
                    write_wrap_block_q <= 1'b1;
                end else begin
                    next_write_id_q <= next_write_id_q + WRITE_ID_W'(1);
                end
            end

            if (exact_live_ack) begin
                write_issued_q <= 1'b0;
                probe_valid_q <= 1'b0;
            end
        end
    end
endmodule
