`timescale 1ns/1ps

/*
 * PROD-SEAM-P7 bounded store terminal-to-load-backend visibility fence.
 *
 * One legacy physical store may be active per production CU.  A successful
 * backend terminal response is retained until the external visibility-commit
 * channel accepts the exact launch address/data payload.  Only that commit
 * handshake releases the terminal response to the predecessor frontend.
 * Faulting store responses bypass the commit channel unchanged.
 */
module a0_store_visibility_commit_fence #(
    parameter integer WAVE_SIZE = 32,
    parameter integer WAVE_ID_W = 2,
    parameter integer CONTEXT_ID_W = WAVE_ID_W
) (
    input logic clk,
    input logic rst_n,

    input logic store_launch_valid_i,
    input logic [WAVE_ID_W-1:0] store_launch_wave_i,
    input logic [CONTEXT_ID_W-1:0] store_launch_context_i,
    input logic [WAVE_SIZE-1:0] store_launch_lane_mask_i,
    input logic [31:0] store_launch_word_addr_i [0:WAVE_SIZE-1],
    input logic [31:0] store_launch_wdata_i [0:WAVE_SIZE-1],

    input logic backend_resp_valid_i,
    input logic [WAVE_ID_W-1:0] backend_resp_wave_i,
    input logic [CONTEXT_ID_W-1:0] backend_resp_context_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_rdata_i [0:WAVE_SIZE-1],

    output logic frontend_resp_valid_o,
    output logic [WAVE_ID_W-1:0] frontend_resp_wave_o,
    output logic [CONTEXT_ID_W-1:0] frontend_resp_context_o,
    output logic frontend_resp_fault_o,
    output logic [31:0] frontend_resp_rdata_o [0:WAVE_SIZE-1],

    output logic visibility_commit_valid_o,
    input logic visibility_commit_ready_i,
    output logic [WAVE_SIZE-1:0] visibility_commit_lane_mask_o,
    output logic [31:0] visibility_commit_word_addr_o [0:WAVE_SIZE-1],
    output logic [31:0] visibility_commit_wdata_o [0:WAVE_SIZE-1],

    output logic store_pending_o
);
    logic active_store_valid_q;
    logic [WAVE_ID_W-1:0] active_store_wave_q;
    logic [CONTEXT_ID_W-1:0] active_store_context_q;
    logic [WAVE_SIZE-1:0] active_store_lane_mask_q;
    logic [31:0] active_store_word_addr_q [0:WAVE_SIZE-1];
    logic [31:0] active_store_wdata_q [0:WAVE_SIZE-1];

    logic held_success_resp_q;
    logic [WAVE_ID_W-1:0] held_resp_wave_q;
    logic [CONTEXT_ID_W-1:0] held_resp_context_q;
    logic [31:0] held_resp_rdata_q [0:WAVE_SIZE-1];

    logic backend_matches_active;
    logic direct_fault_terminal;
    logic commit_release_terminal;

    always_comb begin
        backend_matches_active = backend_resp_valid_i
            && active_store_valid_q
            && backend_resp_wave_i == active_store_wave_q
            && backend_resp_context_i == active_store_context_q;

        direct_fault_terminal = backend_matches_active
            && backend_resp_fault_i
            && !held_success_resp_q;

        commit_release_terminal = held_success_resp_q
            && visibility_commit_ready_i;

        frontend_resp_valid_o = 1'b0;
        frontend_resp_wave_o = backend_resp_wave_i;
        frontend_resp_context_o = backend_resp_context_i;
        frontend_resp_fault_o = backend_resp_fault_i;
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1)
            frontend_resp_rdata_o[lane] = backend_resp_rdata_i[lane];

        if (direct_fault_terminal) begin
            frontend_resp_valid_o = 1'b1;
        end else if (commit_release_terminal) begin
            frontend_resp_valid_o = 1'b1;
            frontend_resp_wave_o = held_resp_wave_q;
            frontend_resp_context_o = held_resp_context_q;
            frontend_resp_fault_o = 1'b0;
            for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1)
                frontend_resp_rdata_o[lane] = held_resp_rdata_q[lane];
        end else if (backend_resp_valid_i && !backend_matches_active
            && !held_success_resp_q) begin
            /* Preserve predecessor diagnostics for unrelated/mistagged traffic. */
            frontend_resp_valid_o = 1'b1;
        end

        visibility_commit_valid_o = held_success_resp_q;
        visibility_commit_lane_mask_o = active_store_lane_mask_q;
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            visibility_commit_word_addr_o[lane] = active_store_word_addr_q[lane];
            visibility_commit_wdata_o[lane] = active_store_wdata_q[lane];
        end

        store_pending_o = active_store_valid_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_store_valid_q <= 1'b0;
            active_store_wave_q <= '0;
            active_store_context_q <= '0;
            active_store_lane_mask_q <= '0;
            held_success_resp_q <= 1'b0;
            held_resp_wave_q <= '0;
            held_resp_context_q <= '0;
            for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                active_store_word_addr_q[lane] <= '0;
                active_store_wdata_q[lane] <= '0;
                held_resp_rdata_q[lane] <= '0;
            end
        end else begin
            if (backend_resp_valid_i && held_success_resp_q)
                $fatal(1, "PROD_SEAM_P7_RESPONSE_WHILE_COMMIT_PENDING");

            if (backend_matches_active && !backend_resp_fault_i) begin
                held_success_resp_q <= 1'b1;
                held_resp_wave_q <= backend_resp_wave_i;
                held_resp_context_q <= backend_resp_context_i;
                for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1)
                    held_resp_rdata_q[lane] <= backend_resp_rdata_i[lane];
            end

            if (direct_fault_terminal) begin
                active_store_valid_q <= 1'b0;
                held_success_resp_q <= 1'b0;
            end

            if (commit_release_terminal) begin
                active_store_valid_q <= 1'b0;
                held_success_resp_q <= 1'b0;
            end

            /* Same-cycle terminal + next launch is legal; the new launch wins. */
            if (store_launch_valid_i) begin
                if (active_store_valid_q && !commit_release_terminal
                    && !direct_fault_terminal)
                    $fatal(1, "PROD_SEAM_P7_STORE_LAUNCH_WHILE_PENDING");
                active_store_valid_q <= 1'b1;
                active_store_wave_q <= store_launch_wave_i;
                active_store_context_q <= store_launch_context_i;
                active_store_lane_mask_q <= store_launch_lane_mask_i;
                for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                    active_store_word_addr_q[lane] <= store_launch_word_addr_i[lane];
                    active_store_wdata_q[lane] <= store_launch_wdata_i[lane];
                end
            end
        end
    end
endmodule
