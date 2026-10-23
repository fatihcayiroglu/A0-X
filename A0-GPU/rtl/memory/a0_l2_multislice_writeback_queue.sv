`timescale 1ns/1ps

/*
 * PROD-SEAM-P20 bounded per-slice writeback queue + round-robin backend arbiter.
 * One captured command and one live backend attempt are allowed per source.
 * Backend identity is {source_id, local_attempt_id}; completion is routed only
 * to the exact live source/attempt. Sources retain their own P19 durability and
 * recovery semantics.
 */
module a0_l2_multislice_writeback_queue #(
    parameter integer SOURCE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer LINE_ADDR_W = 29,
    parameter integer LOCAL_ATTEMPT_ID_W = 9,
    parameter integer SOURCE_ID_W = (SOURCE_COUNT <= 1) ? 1 : $clog2(SOURCE_COUNT),
    parameter integer BACKEND_ATTEMPT_ID_W = SOURCE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer COUNT_W = (SOURCE_COUNT <= 1) ? 1 : $clog2(SOURCE_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic [SOURCE_COUNT-1:0] src_valid_i,
    output logic [SOURCE_COUNT-1:0] src_ready_o,
    input logic [LOCAL_ATTEMPT_ID_W-1:0] src_attempt_id_i [0:SOURCE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] src_line_addr_i [0:SOURCE_COUNT-1],
    input logic [31:0] src_data_i [0:SOURCE_COUNT-1][0:LINE_WORDS-1],

    output logic [SOURCE_COUNT-1:0] src_status_valid_o,
    output logic [LOCAL_ATTEMPT_ID_W-1:0] src_status_attempt_id_o [0:SOURCE_COUNT-1],
    output logic src_status_success_o [0:SOURCE_COUNT-1],
    output logic src_status_retryable_o [0:SOURCE_COUNT-1],

    output logic backend_valid_o,
    input logic backend_ready_i,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_line_addr_o,
    output logic [31:0] backend_data_o [0:LINE_WORDS-1],

    input logic backend_status_valid_i,
    input logic [BACKEND_ATTEMPT_ID_W-1:0] backend_status_attempt_id_i,
    input logic backend_status_success_i,
    input logic backend_status_retryable_i,

    output logic [COUNT_W-1:0] pending_count_o,
    output logic [COUNT_W-1:0] active_count_o,
    output logic protocol_error_o
);
    logic pending_q [0:SOURCE_COUNT-1];
    logic active_q [0:SOURCE_COUNT-1];
    logic [LOCAL_ATTEMPT_ID_W-1:0] pending_attempt_q [0:SOURCE_COUNT-1];
    logic [LOCAL_ATTEMPT_ID_W-1:0] active_attempt_q [0:SOURCE_COUNT-1];
    logic [LINE_ADDR_W-1:0] pending_line_q [0:SOURCE_COUNT-1];
    logic [31:0] pending_data_q [0:SOURCE_COUNT-1][0:LINE_WORDS-1];
    logic [SOURCE_ID_W-1:0] rr_q;

    logic select_found;
    logic [SOURCE_ID_W-1:0] select_source;
    logic backend_fire;
    logic [SOURCE_ID_W-1:0] status_source;
    logic [LOCAL_ATTEMPT_ID_W-1:0] status_local_attempt;
    logic status_source_valid;
    logic status_active_match;
    logic status_issue_match;
    logic status_exact_match;
    integer off;
    integer scan;
    integer comb_source;
    integer comb_word;
    integer seq_source;
    integer seq_word;
    integer pending_count;
    integer active_count;
    integer reset_source;
    integer reset_word;

    initial begin
        if (SOURCE_COUNT < 1) $fatal(1, "P20 SOURCE_COUNT must be >=1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "P20 LINE_WORDS must be power of two");
        if (LINE_ADDR_W < 1) $fatal(1, "P20 LINE_ADDR_W must be >=1");
        if (LOCAL_ATTEMPT_ID_W < 1) $fatal(1, "P20 LOCAL_ATTEMPT_ID_W must be >=1");
    end

    always_comb begin
        for (comb_source = 0; comb_source < SOURCE_COUNT; comb_source = comb_source + 1)
            src_ready_o[comb_source] = rst_n && !pending_q[comb_source] && !active_q[comb_source];

        select_found = 1'b0;
        select_source = '0;
        for (off = 0; off < SOURCE_COUNT; off = off + 1) begin
            scan = integer'(rr_q) + off;
            if (scan >= SOURCE_COUNT) scan = scan - SOURCE_COUNT;
            if (!select_found && pending_q[scan]) begin
                select_found = 1'b1;
                select_source = SOURCE_ID_W'(scan);
            end
        end

        backend_valid_o = select_found;
        backend_attempt_id_o = '0;
        backend_line_addr_o = '0;
        for (comb_word = 0; comb_word < LINE_WORDS; comb_word = comb_word + 1) backend_data_o[comb_word] = '0;
        if (select_found) begin
            backend_attempt_id_o = {select_source, pending_attempt_q[integer'(select_source)]};
            backend_line_addr_o = pending_line_q[integer'(select_source)];
            for (comb_word = 0; comb_word < LINE_WORDS; comb_word = comb_word + 1)
                backend_data_o[comb_word] = pending_data_q[integer'(select_source)][comb_word];
        end
        backend_fire = backend_valid_o && backend_ready_i;

        status_source = backend_status_attempt_id_i[BACKEND_ATTEMPT_ID_W-1 -: SOURCE_ID_W];
        status_local_attempt = backend_status_attempt_id_i[LOCAL_ATTEMPT_ID_W-1:0];
        status_source_valid = integer'(status_source) < SOURCE_COUNT;
        status_active_match = 1'b0;
        if (backend_status_valid_i && status_source_valid)
            status_active_match = active_q[integer'(status_source)]
                && active_attempt_q[integer'(status_source)] == status_local_attempt;
        status_issue_match = backend_fire && backend_status_valid_i
            && status_source_valid && status_source == select_source
            && pending_attempt_q[integer'(select_source)] == status_local_attempt;
        status_exact_match = backend_status_valid_i && (status_active_match || status_issue_match);

        src_status_valid_o = '0;
        for (comb_source = 0; comb_source < SOURCE_COUNT; comb_source = comb_source + 1) begin
            src_status_attempt_id_o[comb_source] = '0;
            src_status_success_o[comb_source] = 1'b0;
            src_status_retryable_o[comb_source] = 1'b0;
        end
        if (status_exact_match) begin
            src_status_valid_o[integer'(status_source)] = 1'b1;
            src_status_attempt_id_o[integer'(status_source)] = status_local_attempt;
            src_status_success_o[integer'(status_source)] = backend_status_success_i;
            src_status_retryable_o[integer'(status_source)] = backend_status_retryable_i;
        end

        pending_count = 0;
        active_count = 0;
        for (comb_source = 0; comb_source < SOURCE_COUNT; comb_source = comb_source + 1) begin
            if (pending_q[comb_source]) pending_count = pending_count + 1;
            if (active_q[comb_source]) active_count = active_count + 1;
        end
        pending_count_o = COUNT_W'(pending_count);
        active_count_o = COUNT_W'(active_count);
        protocol_error_o = backend_status_valid_i && !status_exact_match;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rr_q <= '0;
            for (reset_source = 0; reset_source < SOURCE_COUNT; reset_source = reset_source + 1) begin
                pending_q[reset_source] <= 1'b0;
                active_q[reset_source] <= 1'b0;
                pending_attempt_q[reset_source] <= '0;
                active_attempt_q[reset_source] <= '0;
                pending_line_q[reset_source] <= '0;
                for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                    pending_data_q[reset_source][reset_word] <= '0;
            end
        end else begin
            for (seq_source = 0; seq_source < SOURCE_COUNT; seq_source = seq_source + 1) begin
                if (src_valid_i[seq_source] && src_ready_o[seq_source]) begin
                    pending_q[seq_source] <= 1'b1;
                    pending_attempt_q[seq_source] <= src_attempt_id_i[seq_source];
                    pending_line_q[seq_source] <= src_line_addr_i[seq_source];
                    for (seq_word = 0; seq_word < LINE_WORDS; seq_word = seq_word + 1)
                        pending_data_q[seq_source][seq_word] <= src_data_i[seq_source][seq_word];
                end
            end

            if (backend_fire) begin
                pending_q[integer'(select_source)] <= 1'b0;
                if (!status_issue_match) begin
                    active_q[integer'(select_source)] <= 1'b1;
                    active_attempt_q[integer'(select_source)] <= pending_attempt_q[integer'(select_source)];
                end
                if (integer'(select_source) == SOURCE_COUNT - 1) rr_q <= '0;
                else rr_q <= select_source + SOURCE_ID_W'(1);
            end

            if (status_active_match)
                active_q[integer'(status_source)] <= 1'b0;
        end
    end
endmodule
