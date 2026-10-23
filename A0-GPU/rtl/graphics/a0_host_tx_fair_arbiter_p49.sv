`timescale 1ns/1ps
// P49 EXPERIMENTAL fair complete-frame arbiter.  Not a physical host PHY.
// 16-byte A0GR result frames and 32-byte A0GF telemetry frames are atomic.
// With both channels continuously valid and downstream accepting bytes, they
// alternate at frame boundaries; on reset the result channel wins the first tie.
// An established grant cannot be preempted by an arriving high-priority frame.
// Both upstream sources MUST hold valid/data stable until each byte is accepted.
module a0_host_tx_fair_arbiter_p49 (
    input  logic clk, rst_n,
    input  logic result_valid,
    output logic result_ready,
    input  logic [7:0] result_byte,
    input  logic telemetry_valid,
    output logic telemetry_ready,
    input  logic [7:0] telemetry_byte,
    output logic host_valid,
    input  logic host_ready,
    output logic [7:0] host_byte
);
    typedef enum logic [1:0] {IDLE, RESULT, TELEMETRY} state_t;
    state_t state_q;
    logic [5:0] index_q;
    // 0: choose results on tie; 1: choose telemetry on tie.
    logic prefer_telemetry_q;

    assign host_valid = rst_n && ((state_q == RESULT && result_valid) ||
                                  (state_q == TELEMETRY && telemetry_valid));
    assign host_byte = (state_q == RESULT) ? result_byte :
                       (state_q == TELEMETRY) ? telemetry_byte : 8'd0;
    assign result_ready = rst_n && state_q == RESULT && host_ready;
    assign telemetry_ready = rst_n && state_q == TELEMETRY && host_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            index_q <= '0;
            prefer_telemetry_q <= 1'b0;
        end else if (state_q == IDLE) begin
            if (result_valid && telemetry_valid) begin
                state_q <= prefer_telemetry_q ? TELEMETRY : RESULT;
            end else if (result_valid) begin
                state_q <= RESULT;
            end else if (telemetry_valid) begin
                state_q <= TELEMETRY;
            end
        end else if (host_valid && host_ready) begin
            if (state_q == RESULT && index_q == 6'd15) begin
                state_q <= IDLE;
                index_q <= '0;
                prefer_telemetry_q <= 1'b1;
            end else if (state_q == TELEMETRY && index_q == 6'd31) begin
                state_q <= IDLE;
                index_q <= '0;
                prefer_telemetry_q <= 1'b0;
            end else begin
                index_q <= index_q + 6'd1;
            end
        end
    end
endmodule
