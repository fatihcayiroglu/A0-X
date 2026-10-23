`timescale 1ns/1ps

/* PROD-SEAM-P19: local guard-only recovery sequencing after terminal writeback failure. */
module a0_l2_writeback_recovery_controller (
    input logic clk,
    input logic rst_n,
    input logic wb_terminal_failure_i,
    input logic backend_recovery_safe_valid_i,
    output logic backend_recovery_safe_ready_o,
    output logic guard_rst_n_o,
    output logic recovery_active_o,
    output logic recovery_complete_pulse_o
);
    typedef enum logic [1:0] {NORMAL, WAIT_SAFE, RESET_GUARD, REARM} state_t;
    state_t state_q;

    always_comb begin
        backend_recovery_safe_ready_o = (state_q == WAIT_SAFE);
        guard_rst_n_o = rst_n && (state_q != RESET_GUARD);
        recovery_active_o = (state_q != NORMAL);
        recovery_complete_pulse_o = (state_q == REARM);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= NORMAL;
        end else begin
            case (state_q)
                NORMAL: begin
                    if (wb_terminal_failure_i) state_q <= WAIT_SAFE;
                end
                WAIT_SAFE: begin
                    if (backend_recovery_safe_valid_i && backend_recovery_safe_ready_o)
                        state_q <= RESET_GUARD;
                end
                RESET_GUARD: state_q <= REARM;
                REARM: state_q <= NORMAL;
                default: state_q <= NORMAL;
            endcase
        end
    end
endmodule
