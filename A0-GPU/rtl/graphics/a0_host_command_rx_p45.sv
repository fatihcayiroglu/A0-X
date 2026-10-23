`timescale 1ns/1ps
// P45 EXPERIMENTAL host-frame-to-P43 command decoder.
// Receives ONE byte per accepted clock. The most recently accepted 32-byte
// window is checked against the exact P44 wire framing and IEEE CRC32.
// Every malformed candidate is discarded without dispatch. Sliding-window
// scanning supports magic recovery even when a corrupted frame contains a
// following/overlapping valid header. A validated command is held stable until
// cmd_ready; no input bytes are accepted while the command is pending.
// No physical bus, DMA, result/response encoder, timeout, or PCIe logic.
module a0_host_command_rx_p45 (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    output logic in_ready,
    input  logic [7:0] in_byte,
    output logic cmd_valid,
    input  logic cmd_ready,
    output logic [1:0] cmd_opcode,
    output logic [15:0] cmd_tag,
    output logic [23:0] cmd_color,
    output logic signed [15:0] cmd_x0, cmd_y0, cmd_x1, cmd_y1, cmd_x2, cmd_y2,
    output logic [31:0] invalid_frame_count
);
    // Shift direction places earliest received byte in [7:0] when 32
    // consecutive bytes have been received. No dynamic part select is used.
    logic [255:0] window_q;
    logic [5:0] collected_q;
    logic [255:0] candidate;
    logic [31:0] candidate_crc;
    logic candidate_magic;
    logic candidate_canonical;
    logic candidate_valid;
    logic [7:0] opcode_byte;
    logic [23:0] color_field;
    logic [95:0] vertex_field;

    // Reflected standard CRC32 (zlib/IEEE): initial and final XOR=FFFFFFFF.
    // This is a correctness-first combinational decoder, not timing optimized.
    function automatic logic [31:0] crc32_header(input logic [223:0] header);
        logic [31:0] crc;
        crc = 32'hffffffff;
        for (int i=0; i<28; i++) begin
            crc = crc ^ {24'd0,header[(8*i)+:8]};
            for (int j=0; j<8; j++) begin
                if (crc[0]) crc = (crc >> 1) ^ 32'hedb88320;
                else crc = crc >> 1;
            end
        end
        return ~crc;
    endfunction

    assign in_ready = rst_n && !cmd_valid;
    assign candidate = {in_byte, window_q[255:8]};
    assign candidate_crc = crc32_header(candidate[223:0]);
    assign candidate_magic = (candidate[31:0] == 32'h43473041);
    assign opcode_byte = candidate[47:40];
    assign color_field = candidate[87:64];
    assign vertex_field = candidate[191:96];
    assign candidate_canonical =
        (candidate[39:32] == 8'd1) &&         // version
        (opcode_byte <= 8'd3) &&
        (candidate[95:88] == 8'd0) &&         // color high byte
        (candidate[223:192] == 32'd0) &&     // reserved
        ((opcode_byte == 8'd1) || (vertex_field == 96'd0)) &&
        ((opcode_byte <= 8'd1) || (color_field == 24'd0));
    assign candidate_valid = candidate_magic && candidate_canonical &&
                             (candidate[255:224] == candidate_crc);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            window_q <= '0;
            collected_q <= '0;
            cmd_valid <= 1'b0;
            cmd_opcode <= '0;
            cmd_tag <= '0;
            cmd_color <= '0;
            cmd_x0 <= '0; cmd_y0 <= '0;
            cmd_x1 <= '0; cmd_y1 <= '0;
            cmd_x2 <= '0; cmd_y2 <= '0;
            invalid_frame_count <= '0;
        end else if (cmd_valid) begin
            if (cmd_ready) begin
                cmd_valid <= 1'b0;
                // Restart packet boundary after one dispatched frame.
                window_q <= '0;
                collected_q <= '0;
            end
        end else if (in_valid && in_ready) begin
            window_q <= candidate;
            if (collected_q < 6'd32) collected_q <= collected_q + 6'd1;
            if ((collected_q >= 6'd31) && candidate_magic) begin
                if (candidate_valid) begin
                    cmd_valid <= 1'b1;
                    cmd_opcode <= opcode_byte[1:0];
                    cmd_tag <= candidate[63:48];
                    cmd_color <= color_field;
                    cmd_x0 <= candidate[111:96];
                    cmd_y0 <= candidate[127:112];
                    cmd_x1 <= candidate[143:128];
                    cmd_y1 <= candidate[159:144];
                    cmd_x2 <= candidate[175:160];
                    cmd_y2 <= candidate[191:176];
                end else if (invalid_frame_count != 32'hffffffff) begin
                    invalid_frame_count <= invalid_frame_count + 32'd1;
                end
            end
        end
    end
endmodule
