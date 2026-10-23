`timescale 1ns/1ps

/* PROD-SEAM-P14: bounded watchdog for a lost backend write status.
 * Exact real status always wins over the synthetic timeout event.
 * Timeout is converted only to retryable failure; this module can never
 * synthesize SUCCESS and therefore cannot release predecessor visibility.
 */
module a0_backend_write_status_timeout_guard #(
    parameter integer ATTEMPT_ID_W = 8,
    parameter integer STATUS_TIMEOUT_CYCLES = 32,
    parameter integer TIMEOUT_COUNT_W =
        (STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STATUS_TIMEOUT_CYCLES)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic write_issue_fire_i,
    input  logic [ATTEMPT_ID_W-1:0] write_issue_attempt_id_i,

    input  logic backend_status_valid_i,
    input  logic [ATTEMPT_ID_W-1:0] backend_status_attempt_id_i,
    input  logic backend_status_success_i,
    input  logic backend_status_retryable_i,

    output logic p13_status_valid_o,
    output logic [ATTEMPT_ID_W-1:0] p13_status_attempt_id_o,
    output logic p13_status_success_o,
    output logic p13_status_retryable_o,

    output logic timeout_pulse_o,
    output logic timeout_seen_o,
    output logic watchdog_live_o,
    output logic [TIMEOUT_COUNT_W-1:0] watchdog_count_o
);
    logic live_q;
    logic [ATTEMPT_ID_W-1:0] attempt_id_q;
    logic [TIMEOUT_COUNT_W-1:0] count_q;
    logic timeout_seen_q;
    logic exact_live_external_status;
    logic exact_samecycle_external_status;
    logic exact_external_status;
    logic timeout_fire;

    initial begin
        if (ATTEMPT_ID_W < 1)
            $fatal(1, "PROD_SEAM_P14 ATTEMPT_ID_W must be >= 1");
        if (STATUS_TIMEOUT_CYCLES < 1)
            $fatal(1, "PROD_SEAM_P14 STATUS_TIMEOUT_CYCLES must be >= 1");
        if ((1 << TIMEOUT_COUNT_W) < STATUS_TIMEOUT_CYCLES)
            $fatal(1, "PROD_SEAM_P14 TIMEOUT_COUNT_W too small");
    end

    always_comb begin
        exact_live_external_status = backend_status_valid_i
            && live_q
            && backend_status_attempt_id_i == attempt_id_q;
        exact_samecycle_external_status = backend_status_valid_i
            && write_issue_fire_i
            && backend_status_attempt_id_i == write_issue_attempt_id_i;
        exact_external_status = exact_live_external_status
            || exact_samecycle_external_status;

        timeout_fire = live_q
            && count_q == TIMEOUT_COUNT_W'(STATUS_TIMEOUT_CYCLES - 1)
            && !exact_external_status;

        /* Preserve every real status verbatim so frozen P13 remains the
         * authority for stale/unknown/malformed-status diagnostics. */
        p13_status_valid_o = backend_status_valid_i || timeout_fire;
        p13_status_attempt_id_o = backend_status_valid_i
            ? backend_status_attempt_id_i : attempt_id_q;
        p13_status_success_o = backend_status_valid_i
            ? backend_status_success_i : 1'b0;
        p13_status_retryable_o = backend_status_valid_i
            ? backend_status_retryable_i : timeout_fire;

        timeout_pulse_o = timeout_fire;
        timeout_seen_o = timeout_seen_q;
        watchdog_live_o = live_q;
        watchdog_count_o = count_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            live_q <= 1'b0;
            attempt_id_q <= '0;
            count_q <= '0;
            timeout_seen_q <= 1'b0;
        end else begin
            if (write_issue_fire_i) begin
                attempt_id_q <= write_issue_attempt_id_i;
                count_q <= '0;
                live_q <= !exact_samecycle_external_status;
            end else if (exact_live_external_status || timeout_fire) begin
                live_q <= 1'b0;
                count_q <= '0;
            end else if (live_q) begin
                count_q <= count_q + TIMEOUT_COUNT_W'(1);
            end

            if (timeout_fire)
                timeout_seen_q <= 1'b1;
        end
    end
endmodule
