`timescale 1ns/1ps
// P48 EXPERIMENTAL fixed-frame two-stream serializer arbiter.
// P46 result frames: 16 bytes, P48 telemetry: 32 bytes. Never interleave.
// Registered grant ensures host data never switches while stalled, even if
// another source asserts valid during the stall. Result wins on IDLE grants.
module a0_host_tx_frame_arbiter_p48 (
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

    assign host_valid = rst_n && ((state_q == RESULT && result_valid) ||
                                  (state_q == TELEMETRY && telemetry_valid));
    assign host_byte = (state_q == RESULT) ? result_byte : telemetry_byte;
    assign result_ready = rst_n && state_q == RESULT && host_ready;
    assign telemetry_ready = rst_n && state_q == TELEMETRY && host_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            index_q <= '0;
        end else if (state_q == IDLE) begin
            if (result_valid)
                state_q <= RESULT;
            else if (telemetry_valid)
                state_q <= TELEMETRY;
        end else if (host_valid && host_ready) begin
            if ((state_q == RESULT && index_q == 6'd15) ||
                (state_q == TELEMETRY && index_q == 6'd31)) begin
                state_q <= IDLE;
                index_q <= '0;
            end else begin
                index_q <= index_q + 6'd1;
            end
        end
    end
endmodule
