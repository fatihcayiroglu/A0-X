`timescale 1ns/1ps
// P117 experimental FIFO extension of P48: preserves 32-byte A0GF v1 wire
// format, event sequence and saturating overflow accounting. This is NOT a
// physical host bus. No producer backpressure is available.
// Each entry is a complete immutable packet, never re-written while sending.
// Push on a full FIFO is allowed only if the LAST byte of the oldest packet
// is accepted at the same edge. This avoids unnecessary frame loss.
module a0_scanout_telemetry_fifo_p117 #(
    parameter int FIFO_DEPTH = 4,
    parameter int PTR_BITS = (FIFO_DEPTH <= 2 ? 1 : $clog2(FIFO_DEPTH)),
    parameter int COUNT_BITS = $clog2(FIFO_DEPTH+1)
)(
    input logic clk, rst_n,
    input logic frame_valid, frame_error,
    input logic [31:0] frame_crc32, good_frame_count,
    input logic [31:0] bad_frame_count, aborted_frame_count,
    output logic tx_valid,
    input logic tx_ready,
    output logic [7:0] tx_byte,
    output logic [31:0] dropped_frame_events,
    output logic [COUNT_BITS-1:0] queued_frame_events
);
    logic [255:0] packets [0:FIFO_DEPTH-1];
    logic [PTR_BITS-1:0] rd_q, wr_q;
    logic [4:0] byte_index_q;
    logic [COUNT_BITS-1:0] count_q;
    logic [15:0] event_sequence_q;
    logic [223:0] payload;
    logic finish_packet, push_packet, overflow_event;

    function automatic logic [PTR_BITS-1:0] step_ptr(input logic [PTR_BITS-1:0] p);
        return p == PTR_BITS'(FIFO_DEPTH-1) ? '0 : p + PTR_BITS'(1);
    endfunction
    function automatic logic [31:0] crc32_28(input logic [223:0] data);
        logic [31:0] crc;
        crc = 32'hffffffff;
        for (int i=0;i<28;i++) begin
            crc = crc ^ {24'd0,data[i*8+:8]};
            for (int j=0;j<8;j++)
                crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
        end
        return ~crc;
    endfunction

    assign payload = {dropped_frame_events, aborted_frame_count,
        bad_frame_count, good_frame_count, frame_crc32,
        event_sequence_q, {7'd0,frame_error}, 8'd1, 32'h46473041};
    assign queued_frame_events = count_q;
    assign tx_valid = rst_n && count_q != '0;
    assign tx_byte = count_q != '0 ? packets[rd_q][{byte_index_q,3'b000} +: 8] : 8'd0;
    assign finish_packet = tx_valid && tx_ready && byte_index_q == 5'd31;
    assign push_packet = rst_n && frame_valid && ((count_q < COUNT_BITS'(FIFO_DEPTH)) || finish_packet);
    assign overflow_event = rst_n && frame_valid && !push_packet;

    initial begin
        if (FIFO_DEPTH < 2) $fatal(1,"P117 FIFO_DEPTH must be >= 2");
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_q <= '0;
            wr_q <= '0;
            count_q <= '0;
            byte_index_q <= '0;
            event_sequence_q <= '0;
            dropped_frame_events <= '0;
        end else begin
            if (frame_valid)
                event_sequence_q <= event_sequence_q + 16'd1;
            if (overflow_event && dropped_frame_events != 32'hffffffff)
                dropped_frame_events <= dropped_frame_events + 32'd1;
            if (push_packet) begin
                packets[wr_q] <= {crc32_28(payload), payload};
                wr_q <= step_ptr(wr_q);
            end
            if (tx_valid && tx_ready) begin
                if (finish_packet) begin
                    rd_q <= step_ptr(rd_q);
                    byte_index_q <= '0;
                end else
                    byte_index_q <= byte_index_q + 5'd1;
            end
            case ({push_packet,finish_packet})
                2'b10: count_q <= count_q + COUNT_BITS'(1);
                2'b01: count_q <= count_q - COUNT_BITS'(1);
                default: count_q <= count_q;
            endcase
        end
    end
endmodule
