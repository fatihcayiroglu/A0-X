`timescale 1ns/1ps
// P46 EXPERIMENTAL P44-result wire encoder: one outstanding 16-byte frame.
// Result status is OK(0) or COMMAND_ERROR(1). TIMEOUT is not generated here.
// The cycles field is SUPPLIED BY THE CALLER; it is not P44 Python cycles.
// Source handshake captures all inputs atomically. Output is stable on stall.
// CRC32 IEEE reflected, little endian, bytes 0..11 inclusive.
module a0_host_result_tx_p46 (
    input logic clk, rst_n,
    input logic result_valid,
    output logic result_ready,
    input logic [15:0] result_tag,
    input logic result_error,
    input logic [31:0] result_cycles,
    output logic out_valid,
    input logic out_ready,
    output logic [7:0] out_byte
);
    logic occupied_q;
    logic [3:0] byte_index_q;
    logic [127:0] frame_q;
    logic [95:0] result_header;

    function automatic logic [31:0] crc32_12(input logic [95:0] header);
        logic [31:0] crc;
        crc = 32'hffffffff;
        for (int i = 0; i < 12; i++) begin
            crc ^= {24'd0, header[(i*8)+:8]};
            for (int j = 0; j < 8; j++) begin
                crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
            end
        end
        return ~crc;
    endfunction

    // Byte order: 'A', '0', 'G', 'R', version, status, tag_lo, tag_hi,
    // cycles[7:0] .. cycles[31:24], CRC32 in little endian.
    assign result_header = {result_cycles, result_tag,
                            (result_error ? 8'd1 : 8'd0), 8'd1,
                            32'h52473041};
    assign result_ready = rst_n && !occupied_q;
    assign out_valid = rst_n && occupied_q;
    assign out_byte = frame_q[{byte_index_q, 3'b000} +: 8];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            occupied_q <= 1'b0;
            byte_index_q <= 4'd0;
            frame_q <= '0;
        end else if (occupied_q) begin
            if (out_ready) begin
                if (byte_index_q == 4'd15) begin
                    occupied_q <= 1'b0;
                    byte_index_q <= 4'd0;
                end else begin
                    byte_index_q <= byte_index_q + 4'd1;
                end
            end
        end else if (result_valid && result_ready) begin
            frame_q <= {crc32_12(result_header), result_header};
            occupied_q <= 1'b1;
            byte_index_q <= 4'd0;
        end
    end
endmodule
