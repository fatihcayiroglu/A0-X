`timescale 1ns/1ps

/* PROD-SEAM-P27: bounded status liveness guard for the frozen P26 STORE_WORD
 * completion contract.  A missing backend status is converted only into an
 * explicit terminal failure status for the exact accepted attempt; it is
 * never converted into success.  Real matching status has deadline priority. */
module a0_store_word_status_timeout_guard #(
    parameter integer ATTEMPT_ID_W = 10,
    parameter integer STATUS_TIMEOUT_CYCLES = 16,
    parameter integer TIMER_W = (STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STATUS_TIMEOUT_CYCLES)
) (
    input logic clk,
    input logic rst_n,

    input logic store_cmd_fire_i,
    input logic [ATTEMPT_ID_W-1:0] store_cmd_attempt_id_i,

    input logic backend_status_valid_i,
    input logic [ATTEMPT_ID_W-1:0] backend_status_attempt_id_i,
    input logic backend_status_success_i,
    input logic backend_status_retryable_i,

    output logic guarded_status_valid_o,
    output logic [ATTEMPT_ID_W-1:0] guarded_status_attempt_id_o,
    output logic guarded_status_success_o,
    output logic guarded_status_retryable_o,

    output logic live_o,
    output logic [TIMER_W-1:0] age_o,
    output logic timeout_pulse_o,
    output logic timeout_seen_o,
    output logic protocol_error_o
);
    logic live_q;
    logic [ATTEMPT_ID_W-1:0] attempt_id_q;
    logic [TIMER_W-1:0] age_q;
    logic timeout_seen_q, timeout_pulse_q, protocol_error_q;

    logic cmd_status_match;
    logic live_status_match;
    logic real_match;
    logic timeout_fire;
    logic stray_status;

    initial begin
        if (ATTEMPT_ID_W < 1) $fatal(1, "P27 ATTEMPT_ID_W must be >=1");
        if (STATUS_TIMEOUT_CYCLES < 1) $fatal(1, "P27 STATUS_TIMEOUT_CYCLES must be >=1");
    end

    always_comb begin
        cmd_status_match = store_cmd_fire_i && backend_status_valid_i
            && backend_status_attempt_id_i == store_cmd_attempt_id_i;
        live_status_match = live_q && backend_status_valid_i
            && backend_status_attempt_id_i == attempt_id_q;
        real_match = cmd_status_match || live_status_match;

        timeout_fire = live_q && !live_status_match
            && (integer'(age_q) == STATUS_TIMEOUT_CYCLES-1);

        stray_status = backend_status_valid_i && !real_match;

        guarded_status_valid_o = real_match || timeout_fire;
        guarded_status_attempt_id_o = live_q ? attempt_id_q : store_cmd_attempt_id_i;
        guarded_status_success_o = real_match ? backend_status_success_i : 1'b0;
        guarded_status_retryable_o = real_match ? backend_status_retryable_i : 1'b0;

        live_o = live_q;
        age_o = age_q;
        timeout_pulse_o = timeout_pulse_q;
        timeout_seen_o = timeout_seen_q;
        protocol_error_o = protocol_error_q || stray_status || (store_cmd_fire_i && live_q);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            live_q <= 1'b0;
            attempt_id_q <= '0;
            age_q <= '0;
            timeout_seen_q <= 1'b0;
            timeout_pulse_q <= 1'b0;
            protocol_error_q <= 1'b0;
        end else begin
            timeout_pulse_q <= 1'b0;

            if (stray_status || (store_cmd_fire_i && live_q))
                protocol_error_q <= 1'b1;

            if (live_q) begin
                if (live_status_match) begin
                    live_q <= 1'b0;
                    age_q <= '0;
                end else if (timeout_fire) begin
                    live_q <= 1'b0;
                    age_q <= '0;
                    timeout_seen_q <= 1'b1;
                    timeout_pulse_q <= 1'b1;
                end else begin
                    age_q <= age_q + TIMER_W'(1);
                end
            end else if (store_cmd_fire_i) begin
                if (cmd_status_match) begin
                    live_q <= 1'b0;
                    age_q <= '0;
                end else begin
                    live_q <= 1'b1;
                    attempt_id_q <= store_cmd_attempt_id_i;
                    age_q <= '0;
                end
            end
        end
    end
endmodule
