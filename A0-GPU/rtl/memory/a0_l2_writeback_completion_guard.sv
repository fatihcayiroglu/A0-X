`timescale 1ns/1ps

/* PROD-SEAM-P18 durable dirty-victim writeback completion guard. */
module a0_l2_writeback_completion_guard #(
    parameter integer LINE_WORDS = 8,
    parameter integer LINE_ADDR_W = 29,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_RETRIES = 2,
    parameter integer RETRY_W = (MAX_RETRIES < 1) ? 1 : $clog2(MAX_RETRIES + 1),
    parameter integer ATTEMPT_ID_W = WRITE_ID_W + RETRY_W
) (
    input logic clk,
    input logic rst_n,

    input logic victim_wb_valid_i,
    output logic victim_wb_ready_o,
    input logic [LINE_ADDR_W-1:0] victim_wb_line_addr_i,
    input logic [31:0] victim_wb_data_i [0:LINE_WORDS-1],

    output logic backend_wb_valid_o,
    input logic backend_wb_ready_i,
    output logic [ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_wb_line_addr_o,
    output logic [31:0] backend_wb_data_o [0:LINE_WORDS-1],

    input logic backend_wb_status_valid_i,
    input logic [ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,

    output logic busy_o,
    output logic [RETRY_W-1:0] retry_count_o,
    output logic terminal_failure_o,
    output logic protocol_error_o
);
    typedef enum logic [1:0] {IDLE, ISSUE, WAIT_STATUS, FAIL_CLOSED} state_t;
    state_t state_q;

    logic [WRITE_ID_W-1:0] write_id_q;
    logic [RETRY_W-1:0] retry_q;
    logic [LINE_ADDR_W-1:0] line_q;
    logic [31:0] data_q [0:LINE_WORDS-1];
    logic protocol_error_q;

    logic backend_fire;
    logic status_window;
    logic status_match;
    logic status_success_fire;
    logic status_retry_fire;
    logic status_terminal_fire;
    logic source_payload_match;
    integer word;
    integer reset_word;

    initial begin
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "P18 LINE_WORDS must be power of two");
        if (LINE_ADDR_W < 1) $fatal(1, "P18 LINE_ADDR_W must be >=1");
        if (WRITE_ID_W < 1) $fatal(1, "P18 WRITE_ID_W must be >=1");
        if (MAX_RETRIES < 0) $fatal(1, "P18 MAX_RETRIES must be >=0");
    end

    always_comb begin
        backend_wb_valid_o = (state_q == ISSUE);
        backend_wb_attempt_id_o = {write_id_q, retry_q};
        backend_wb_line_addr_o = line_q;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            backend_wb_data_o[word] = data_q[word];

        backend_fire = backend_wb_valid_o && backend_wb_ready_i;
        status_window = (state_q == WAIT_STATUS) || ((state_q == ISSUE) && backend_fire);
        status_match = backend_wb_status_valid_i && status_window
            && backend_wb_status_attempt_id_i == backend_wb_attempt_id_o;

        source_payload_match = victim_wb_valid_i && victim_wb_line_addr_i == line_q;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            if (victim_wb_data_i[word] != data_q[word]) source_payload_match = 1'b0;

        status_success_fire = status_match && backend_wb_status_success_i;
        status_retry_fire = status_match && !backend_wb_status_success_i
            && backend_wb_status_retryable_i && (integer'(retry_q) < MAX_RETRIES);
        status_terminal_fire = status_match && !backend_wb_status_success_i
            && (!backend_wb_status_retryable_i || (integer'(retry_q) >= MAX_RETRIES));

        victim_wb_ready_o = status_success_fire && source_payload_match;
        busy_o = (state_q != IDLE);
        retry_count_o = retry_q;
        terminal_failure_o = (state_q == FAIL_CLOSED);
        protocol_error_o = protocol_error_q
            || (backend_wb_status_valid_i && !status_match)
            || ((state_q != IDLE) && !victim_wb_valid_i)
            || ((state_q != IDLE) && victim_wb_valid_i && !source_payload_match);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            write_id_q <= '0;
            retry_q <= '0;
            line_q <= '0;
            protocol_error_q <= 1'b0;
            for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                data_q[reset_word] <= '0;
        end else begin
            if (backend_wb_status_valid_i && !status_match)
                protocol_error_q <= 1'b1;
            if ((state_q != IDLE) && (!victim_wb_valid_i || !source_payload_match))
                protocol_error_q <= 1'b1;

            case (state_q)
                IDLE: begin
                    retry_q <= '0;
                    if (victim_wb_valid_i) begin
                        line_q <= victim_wb_line_addr_i;
                        for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                            data_q[reset_word] <= victim_wb_data_i[reset_word];
                        state_q <= ISSUE;
                    end
                end
                ISSUE: begin
                    if (backend_fire) begin
                        if (status_success_fire) begin
                            if (!source_payload_match) begin
                                protocol_error_q <= 1'b1;
                                state_q <= FAIL_CLOSED;
                            end else begin
                                state_q <= IDLE;
                                write_id_q <= write_id_q + WRITE_ID_W'(1);
                            end
                        end else if (status_retry_fire) begin
                            retry_q <= retry_q + RETRY_W'(1);
                            state_q <= ISSUE;
                        end else if (status_terminal_fire) begin
                            state_q <= FAIL_CLOSED;
                        end else begin
                            state_q <= WAIT_STATUS;
                        end
                    end
                end
                WAIT_STATUS: begin
                    if (status_success_fire) begin
                        if (!source_payload_match) begin
                            protocol_error_q <= 1'b1;
                            state_q <= FAIL_CLOSED;
                        end else begin
                            state_q <= IDLE;
                            write_id_q <= write_id_q + WRITE_ID_W'(1);
                        end
                    end else if (status_retry_fire) begin
                        retry_q <= retry_q + RETRY_W'(1);
                        state_q <= ISSUE;
                    end else if (status_terminal_fire) begin
                        state_q <= FAIL_CLOSED;
                    end
                end
                default: state_q <= FAIL_CLOSED;
            endcase
        end
    end
endmodule
