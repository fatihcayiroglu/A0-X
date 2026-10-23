`timescale 1ns/1ps
// P111 research instrumentation. Non-intrusive, one outstanding command.
// Measures acceptance-to-first-response latency, NOT host packet delivery.
// A response held by backpressure is allowed for unlimited cycles, provided
// valid, tag and error remain stable. On violation the monitor latches FAULT
// until reset, never pretending to reset/retry the original GPU command.
module a0_command_completion_watchdog_p111 #(
    parameter int MAX_WAIT_CYCLES = 4096
)(
    input logic clk, rst_n,
    input logic cmd_valid, cmd_ready,
    input logic [15:0] cmd_tag,
    input logic completion_valid, completion_ready,
    input logic [15:0] completion_tag,
    input logic completion_error,
    output logic fault_sticky, pending,
    output logic [15:0] active_tag, last_fault_tag,
    output logic [31:0] timeout_count, tag_mismatch_count,
    output logic [31:0] protocol_fault_count, completed_count
);
    typedef enum logic [1:0] {IDLE, WAIT_RESPONSE, HOLD_RESPONSE, FAULT} state_t;
    state_t state_q;
    logic [31:0] wait_cycles_q;
    logic held_error_q;
    logic accepting, responding;
    assign accepting = cmd_valid && cmd_ready;
    assign responding = completion_valid;
    assign pending = (state_q == WAIT_RESPONSE || state_q == HOLD_RESPONSE);
    assign fault_sticky = (state_q == FAULT);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            wait_cycles_q <= '0;
            held_error_q <= 1'b0;
            active_tag <= '0;
            last_fault_tag <= '0;
            timeout_count <= '0;
            tag_mismatch_count <= '0;
            protocol_fault_count <= '0;
            completed_count <= '0;
        end else begin
            case (state_q)
                IDLE: begin
                    if (responding) begin
                        state_q <= FAULT;
                        last_fault_tag <= completion_tag;
                        if (protocol_fault_count != 32'hffffffff)
                            protocol_fault_count <= protocol_fault_count + 1'b1;
                    end else if (accepting) begin
                        active_tag <= cmd_tag;
                        wait_cycles_q <= '0;
                        state_q <= WAIT_RESPONSE;
                    end
                end
                WAIT_RESPONSE: begin
                    if (accepting) begin
                        state_q <= FAULT;
                        last_fault_tag <= cmd_tag;
                        if (protocol_fault_count != 32'hffffffff)
                            protocol_fault_count <= protocol_fault_count + 1'b1;
                    end else if (responding) begin
                        if (completion_tag != active_tag) begin
                            state_q <= FAULT;
                            last_fault_tag <= completion_tag;
                            if (tag_mismatch_count != 32'hffffffff)
                                tag_mismatch_count <= tag_mismatch_count + 1'b1;
                        end else if (completion_ready) begin
                            state_q <= IDLE;
                            if (completed_count != 32'hffffffff)
                                completed_count <= completed_count + 1'b1;
                        end else begin
                            held_error_q <= completion_error;
                            state_q <= HOLD_RESPONSE;
                        end
                    end else if (wait_cycles_q >= MAX_WAIT_CYCLES - 1) begin
                        state_q <= FAULT;
                        last_fault_tag <= active_tag;
                        if (timeout_count != 32'hffffffff)
                            timeout_count <= timeout_count + 1'b1;
                    end else begin
                        wait_cycles_q <= wait_cycles_q + 1'b1;
                    end
                end
                HOLD_RESPONSE: begin
                    if (accepting || !responding || completion_tag != active_tag ||
                        completion_error != held_error_q) begin
                        state_q <= FAULT;
                        last_fault_tag <= active_tag;
                        if (protocol_fault_count != 32'hffffffff)
                            protocol_fault_count <= protocol_fault_count + 1'b1;
                    end else if (completion_ready) begin
                        state_q <= IDLE;
                        if (completed_count != 32'hffffffff)
                            completed_count <= completed_count + 1'b1;
                    end
                end
                FAULT: begin
                    // Fail closed: sticky until explicit reset, never restart.
                end
                default: state_q <= FAULT;
            endcase
        end
    end
    initial begin
        if (MAX_WAIT_CYCLES < 1 || MAX_WAIT_CYCLES > 32'h7fffffff)
            $fatal(1, "P111 MAX_WAIT_CYCLES must be in 1..2^31-1");
    end
endmodule
