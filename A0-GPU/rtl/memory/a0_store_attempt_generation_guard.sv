`timescale 1ns/1ps

/* PROD-SEAM-P31: qualify every accepted physical STORE attempt with an
 * independently allocated generation.  The complete local attempt identity
 * remains opaque.  This guard owns only STORE identity/status state; READ and
 * WRITEBACK traffic must bypass it without changing their identifiers.
 *
 * rst_n is the global cold reset, requiring all backend STORE generations to
 * be quiescent.  local_rearm_i masks command/status forwarding but does not
 * reset the allocator, wrap barrier, or rejected-status diagnostic.  A caller
 * must retire the failed local attempt before locally rearming its guards;
 * local rearm is not an implicit cancellation of an outstanding backend write.
 *
 * The local completion/timeout composition owns the one-live-attempt rule.
 * backend_cmd_ready_i must represent this STORE command's actual acceptance
 * opportunity after arbitration, not readiness for an unrelated line command.
 */
module a0_store_attempt_generation_guard #(
    parameter integer LOCAL_ATTEMPT_ID_W = 10,
    parameter integer GENERATION_W = 8,
    parameter integer EXTERNAL_ATTEMPT_ID_W = LOCAL_ATTEMPT_ID_W + GENERATION_W
) (
    input logic clk,
    input logic rst_n,

    input logic local_cmd_valid_i,
    input logic [LOCAL_ATTEMPT_ID_W-1:0] local_cmd_attempt_id_i,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_valid_o,
    output logic [EXTERNAL_ATTEMPT_ID_W-1:0] backend_cmd_attempt_id_o,
    output logic local_cmd_ready_o,

    input logic backend_status_valid_i,
    input logic [EXTERNAL_ATTEMPT_ID_W-1:0] backend_status_attempt_id_i,
    input logic backend_status_success_i,
    input logic backend_status_retryable_i,
    output logic local_status_valid_o,
    output logic [LOCAL_ATTEMPT_ID_W-1:0] local_status_attempt_id_o,
    output logic local_status_success_o,
    output logic local_status_retryable_o,

    input logic local_timeout_live_i,
    input logic local_timeout_pulse_i,
    input logic local_rearm_i,
    input logic backend_all_generations_quiescent_i,

    output logic [GENERATION_W-1:0] next_generation_o,
    output logic wrap_pending_o,
    output logic status_rejected_o,
    output logic attempt_idle_o
);
    logic [GENERATION_W-1:0] generation_next_q;
    logic generation_wrap_pending_q;
    logic attempt_live_q;
    logic [EXTERNAL_ATTEMPT_ID_W-1:0] live_attempt_id_q;
    logic status_rejected_q;

    logic command_fire;
    logic live_status_match;
    logic command_status_match;
    logic wrap_release;

    initial begin
        if (LOCAL_ATTEMPT_ID_W < 1)
            $fatal(1, "P31 LOCAL_ATTEMPT_ID_W must be >=1");
        if (GENERATION_W < 1)
            $fatal(1, "P31 GENERATION_W must be >=1");
        if (EXTERNAL_ATTEMPT_ID_W != LOCAL_ATTEMPT_ID_W + GENERATION_W)
            $fatal(1, "P31 EXTERNAL_ATTEMPT_ID_W must preserve the complete local ID and generation");
    end

    /* Keep offered valid/identity independent of the acceptance/status cone.
     * Arbitration can then use valid to select this source and return ready
     * without creating a procedural-block dependency from ready to valid. */
    assign backend_cmd_valid_o = local_cmd_valid_i && rst_n && !local_rearm_i
        && !generation_wrap_pending_q;
    assign local_cmd_ready_o = backend_cmd_ready_i && rst_n && !local_rearm_i
        && !generation_wrap_pending_q;
    assign backend_cmd_attempt_id_o = {generation_next_q, local_cmd_attempt_id_i};
    assign command_fire = backend_cmd_valid_o && backend_cmd_ready_i;
    assign next_generation_o = generation_next_q;
    assign wrap_pending_o = generation_wrap_pending_q;
    assign status_rejected_o = status_rejected_q;
    assign attempt_idle_o = !attempt_live_q && !local_timeout_live_i;

    always_comb begin
        /* The local timer drops live immediately when its deadline retires.
         * Its registered timeout pulse may arrive one cycle later, so checking
         * both live bits prevents a late status from entering that interval.
         * Same-cycle command/status matching requires the real accepting edge. */
        live_status_match = attempt_live_q && local_timeout_live_i
            && backend_status_attempt_id_i == live_attempt_id_q;
        command_status_match = command_fire
            && backend_status_attempt_id_i == backend_cmd_attempt_id_o;
        local_status_valid_o = backend_status_valid_i && rst_n && !local_rearm_i
            && (live_status_match || command_status_match);
        local_status_attempt_id_o = backend_status_attempt_id_i[LOCAL_ATTEMPT_ID_W-1:0];
        local_status_success_o = local_status_valid_o && backend_status_success_i;
        local_status_retryable_o = local_status_valid_o && backend_status_retryable_i;

        /* This is a current backend certificate that ALL historical statuses,
         * including duplicates, have drained and cannot return.  It is not an
         * idle hint, a failed-attempt certificate, or a proof remembered before
         * exhaustion.  The last allocated attempt remains completable while
         * wrapping is pending; raw status traffic blocks certificate acceptance. */
        wrap_release = generation_wrap_pending_q && !attempt_live_q
            && !local_timeout_live_i && !backend_status_valid_i
            && backend_all_generations_quiescent_i;

    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            generation_next_q <= '0;
            generation_wrap_pending_q <= 1'b0;
            attempt_live_q <= 1'b0;
            live_attempt_id_q <= '0;
            status_rejected_q <= 1'b0;
        end else begin
            if (command_fire) begin
                live_attempt_id_q <= backend_cmd_attempt_id_o;
                attempt_live_q <= !local_status_valid_o;
                generation_next_q <= generation_next_q + GENERATION_W'(1);
                if (&generation_next_q)
                    generation_wrap_pending_q <= 1'b1;
            end else begin
                if (local_status_valid_o || local_timeout_pulse_i)
                    attempt_live_q <= 1'b0;
                if (wrap_release)
                    generation_wrap_pending_q <= 1'b0;
            end

            if (backend_status_valid_i && !local_status_valid_o)
                status_rejected_q <= 1'b1;
        end
    end
endmodule
