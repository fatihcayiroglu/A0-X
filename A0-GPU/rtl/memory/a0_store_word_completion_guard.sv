`timescale 1ns/1ps

/* PROD-SEAM-P26 bounded completion guard for one P25 STORE_WORD source.
 * A source word is never acknowledged on command acceptance alone.  The exact
 * captured word is retried with an explicit attempt incarnation and source
 * ready pulses only for a matching backend SUCCESS.  Terminal failure is
 * fail-closed and intentionally has no recovery in P26. */
module a0_store_word_completion_guard #(
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_RETRIES = 2,
    parameter integer RETRY_W = (MAX_RETRIES < 1) ? 1 : $clog2(MAX_RETRIES + 1),
    parameter integer ATTEMPT_ID_W = WRITE_ID_W + RETRY_W
) (
    input logic clk,
    input logic rst_n,

    input logic store_valid_i,
    output logic store_ready_o,
    input logic [31:0] store_word_addr_i,
    input logic [31:0] store_wdata_i,

    output logic backend_store_valid_o,
    input logic backend_store_ready_i,
    output logic [ATTEMPT_ID_W-1:0] backend_store_attempt_id_o,
    output logic [31:0] backend_store_word_addr_o,
    output logic [31:0] backend_store_wdata_o,

    input logic backend_store_status_valid_i,
    input logic [ATTEMPT_ID_W-1:0] backend_store_status_attempt_id_i,
    input logic backend_store_status_success_i,
    input logic backend_store_status_retryable_i,

    output logic busy_o,
    output logic [RETRY_W-1:0] retry_count_o,
    output logic terminal_failure_o,
    output logic protocol_error_o
);
    typedef enum logic [1:0] {IDLE, ISSUE, WAIT_STATUS, FAIL_CLOSED} state_t;
    state_t state_q;

    logic [WRITE_ID_W-1:0] write_id_q;
    logic [RETRY_W-1:0] retry_q;
    logic [31:0] word_addr_q, wdata_q;
    logic protocol_error_q;

    logic backend_fire;
    logic status_window, status_match;
    logic status_success_fire, status_retry_fire, status_terminal_fire;
    logic source_payload_match;

    initial begin
        if (WRITE_ID_W < 1) $fatal(1, "P26 WRITE_ID_W must be >=1");
        if (MAX_RETRIES < 0) $fatal(1, "P26 MAX_RETRIES must be >=0");
    end

    always_comb begin
        backend_store_valid_o = (state_q == ISSUE);
        backend_store_attempt_id_o = {write_id_q, retry_q};
        backend_store_word_addr_o = word_addr_q;
        backend_store_wdata_o = wdata_q;

        backend_fire = backend_store_valid_o && backend_store_ready_i;
        status_window = (state_q == WAIT_STATUS) || ((state_q == ISSUE) && backend_fire);
        status_match = backend_store_status_valid_i && status_window
            && backend_store_status_attempt_id_i == backend_store_attempt_id_o;

        source_payload_match = store_valid_i
            && store_word_addr_i == word_addr_q
            && store_wdata_i == wdata_q;

        status_success_fire = status_match && backend_store_status_success_i;
        status_retry_fire = status_match && !backend_store_status_success_i
            && backend_store_status_retryable_i && (integer'(retry_q) < MAX_RETRIES);
        status_terminal_fire = status_match && !backend_store_status_success_i
            && (!backend_store_status_retryable_i || (integer'(retry_q) >= MAX_RETRIES));

        store_ready_o = status_success_fire && source_payload_match;
        busy_o = (state_q != IDLE);
        retry_count_o = retry_q;
        terminal_failure_o = (state_q == FAIL_CLOSED);
        protocol_error_o = protocol_error_q
            || (backend_store_status_valid_i && !status_match)
            || ((state_q != IDLE) && !store_valid_i)
            || ((state_q != IDLE) && store_valid_i && !source_payload_match);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            write_id_q <= '0;
            retry_q <= '0;
            word_addr_q <= '0;
            wdata_q <= '0;
            protocol_error_q <= 1'b0;
        end else begin
            if (backend_store_status_valid_i && !status_match)
                protocol_error_q <= 1'b1;
            if ((state_q != IDLE) && (!store_valid_i || !source_payload_match))
                protocol_error_q <= 1'b1;

            case (state_q)
                IDLE: begin
                    retry_q <= '0;
                    if (store_valid_i) begin
                        word_addr_q <= store_word_addr_i;
                        wdata_q <= store_wdata_i;
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
