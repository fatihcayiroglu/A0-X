`timescale 1ns/1ps
// P48 EXPERIMENTAL passive diagnostics -> 32-byte host telemetry packet.
// NOT PCIe/PHY. Cannot backpressure P47: frames arriving while occupied are
// deliberately dropped, counted (saturating), and visible to later packets.
// Source: P47 outputs, which are registered and stable across observation edge.
// Wire layout (little endian): "A0GF", v1, flags(error), seq(u16),
// frame_crc(u32), good(u32), bad(u32), aborted(u32), dropped(u32), crc32(u32).
// CRC32 IEEE over first 28 bytes; sequence increments for EVERY frame event.
module a0_scanout_telemetry_tx_p48 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        frame_valid,
    input  logic        frame_error,
    input  logic [31:0] frame_crc32,
    input  logic [31:0] good_frame_count,
    input  logic [31:0] bad_frame_count,
    input  logic [31:0] aborted_frame_count,
    output logic        tx_valid,
    input  logic        tx_ready,
    output logic [7:0]  tx_byte,
    output logic [31:0] dropped_frame_events
);
    logic occupied_q;
    logic [4:0] index_q;
    logic [255:0] packet_q;
    logic [15:0] event_sequence_q;
    logic [223:0] payload;

    function automatic logic [31:0] crc32_28(input logic [223:0] data);
        logic [31:0] crc;
        crc = 32'hffffffff;
        for (int i = 0; i < 28; i++) begin
            crc = crc ^ {24'd0, data[i*8+:8]};
            for (int j = 0; j < 8; j++) begin
                crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
            end
        end
        return ~crc;
    endfunction

    // RTL concatenation highest bits first. Byte offset 0 is LSB.
    assign payload = {dropped_frame_events, aborted_frame_count,
                      bad_frame_count, good_frame_count, frame_crc32,
                      event_sequence_q, {7'd0, frame_error}, 8'd1,
                      32'h46473041}; // "A0GF" in little-endian order.
    assign tx_valid = rst_n && occupied_q;
    assign tx_byte = packet_q[{index_q,3'b000} +: 8];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            occupied_q <= 1'b0;
            index_q <= '0;
            packet_q <= '0;
            event_sequence_q <= '0;
            dropped_frame_events <= '0;
        end else begin
            if (frame_valid) begin
                event_sequence_q <= event_sequence_q + 16'd1;
                if (!occupied_q) begin
                    packet_q <= {crc32_28(payload), payload};
                    occupied_q <= 1'b1;
                    index_q <= '0;
                end else if (dropped_frame_events != 32'hffffffff) begin
                    // Do not replace/alter the packet already on the wire.
                    dropped_frame_events <= dropped_frame_events + 32'd1;
                end
            end
            if (occupied_q && tx_ready) begin
                if (index_q == 5'd31) begin
                    occupied_q <= 1'b0;
                    index_q <= '0;
                end else begin
                    index_q <= index_q + 5'd1;
                end
            end
        end
    end
endmodule
