`timescale 1ns/1ps
// P47 EXPERIMENTAL passive scanout-integrity monitor, not a video PHY.
// CRC32/IEEE on accepted pixels, byte order blue, green, red (RGB888 LSB first).
// No timing/behavior effect on producer ready/valid path: observations only.
// frame_valid pulses after the last pixel or any accepted early EOF; frame_error
// reports wrong coordinate/sideband or length. An incomplete frame is dropped
// when stream_active is deasserted. Disabled input never consumes a pixel.
module a0_scanout_frame_guard_p47 #(
    parameter int FRAME_WIDTH = 8,
    parameter int FRAME_HEIGHT = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic stream_active,
    input  logic pixel_valid,
    input  logic pixel_ready,
    input  logic [15:0] pixel_x,
    input  logic [15:0] pixel_y,
    input  logic [23:0] pixel_color,
    input  logic start_of_frame,
    input  logic end_of_line,
    input  logic end_of_frame,
    output logic frame_valid,
    output logic frame_error,
    output logic [31:0] frame_crc32,
    output logic [31:0] good_frame_count,
    output logic [31:0] bad_frame_count,
    output logic [31:0] aborted_frame_count
);
    localparam int PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    logic in_frame_q;
    logic [15:0] expected_x_q, expected_y_q;
    logic [31:0] crc_q;
    logic error_q;
    logic [31:0] pixel_count_q;

    function automatic logic [31:0] crc_byte(
        input logic [31:0] running_crc,
        input logic [7:0] byte_value
    );
        logic [31:0] crc;
        crc = running_crc ^ {24'b0, byte_value};
        for (int j=0; j<8; j++) begin
            crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
        end
        return crc;
    endfunction

    logic [31:0] starting_crc, advanced_crc;
    logic [15:0] expected_x, expected_y;
    logic [31:0] beat_count;
    logic expected_sof, expected_eol, expected_eof;
    logic beat_error, finishing;

    assign starting_crc = in_frame_q ? crc_q : 32'hffffffff;
    assign advanced_crc = crc_byte(crc_byte(crc_byte(starting_crc,
                          pixel_color[7:0]),pixel_color[15:8]),pixel_color[23:16]);
    assign expected_x = in_frame_q ? expected_x_q : 16'd0;
    assign expected_y = in_frame_q ? expected_y_q : 16'd0;
    assign beat_count = in_frame_q ? pixel_count_q : 32'd0;
    assign expected_sof = (beat_count == 0);
    assign expected_eol = (expected_x == FRAME_WIDTH - 1);
    assign expected_eof = (beat_count == PIXELS - 1);
    assign beat_error = (pixel_x != expected_x) || (pixel_y != expected_y) ||
                        (start_of_frame != expected_sof) ||
                        (end_of_line != expected_eol) ||
                        (end_of_frame != expected_eof);
    assign finishing = end_of_frame || expected_eof;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            in_frame_q <= 1'b0;
            expected_x_q <= '0;
            expected_y_q <= '0;
            crc_q <= 32'hffffffff;
            error_q <= 1'b0;
            pixel_count_q <= '0;
            frame_valid <= 1'b0;
            frame_error <= 1'b0;
            frame_crc32 <= '0;
            good_frame_count <= '0;
            bad_frame_count <= '0;
            aborted_frame_count <= '0;
        end else begin
            frame_valid <= 1'b0;
            if (!stream_active) begin
                if (in_frame_q && aborted_frame_count != 32'hffffffff)
                    aborted_frame_count <= aborted_frame_count + 32'd1;
                in_frame_q <= 1'b0;
                error_q <= 1'b0;
                expected_x_q <= '0;
                expected_y_q <= '0;
                pixel_count_q <= '0;
                crc_q <= 32'hffffffff;
            end else if (pixel_valid && pixel_ready) begin
                if (finishing) begin
                    // EOF may occur early; it still emits a *bad* observation.
                    frame_valid <= 1'b1;
                    frame_error <= (error_q && in_frame_q) || beat_error;
                    frame_crc32 <= ~advanced_crc;
                    if ((error_q && in_frame_q) || beat_error) begin
                        if (bad_frame_count != 32'hffffffff)
                            bad_frame_count <= bad_frame_count + 32'd1;
                    end else if (good_frame_count != 32'hffffffff) begin
                        good_frame_count <= good_frame_count + 32'd1;
                    end
                    in_frame_q <= 1'b0;
                    error_q <= 1'b0;
                    expected_x_q <= '0;
                    expected_y_q <= '0;
                    pixel_count_q <= '0;
                    crc_q <= 32'hffffffff;
                end else begin
                    in_frame_q <= 1'b1;
                    error_q <= (error_q && in_frame_q) || beat_error;
                    crc_q <= advanced_crc;
                    pixel_count_q <= beat_count + 32'd1;
                    if (expected_eol) begin
                        expected_x_q <= '0;
                        expected_y_q <= expected_y + 16'd1;
                    end else begin
                        expected_x_q <= expected_x + 16'd1;
                        expected_y_q <= expected_y;
                    end
                end
            end
        end
    end
    initial begin
        if (FRAME_WIDTH < 1 || FRAME_HEIGHT < 1 ||
            FRAME_WIDTH > 32767 || FRAME_HEIGHT > 32767 || PIXELS > 65536)
            $fatal(1,"P47 unsupported scanout geometry");
    end
endmodule
