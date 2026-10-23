`timescale 1ns/1ps
// P47 wrapper of the UNMODIFIED P46 host bridge with passive frame diagnostics.
// The CRC monitor taps accepted P42 scanout beats. No PCIe, DDR, GPU shader,
// graphics API, or host-readable register block is implemented here.
module a0_host_graphics_crc_bridge_p47 #(
    parameter int FRAME_WIDTH = 8,
    parameter int FRAME_HEIGHT = 8,
    parameter int PIXELS = FRAME_WIDTH * FRAME_HEIGHT,
    parameter int ADDR_BITS = (PIXELS <= 1 ? 1 : $clog2(PIXELS))
)(
    input logic clk, rst_n,
    input logic rx_valid,
    output logic rx_ready,
    input logic [7:0] rx_byte,
    output logic tx_valid,
    input logic tx_ready,
    output logic [7:0] tx_byte,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x, pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame, end_of_line, end_of_frame, frame_done,
    output logic display_bank, render_bank, display_initialized,
    output logic render_initialized, render_busy, swap_pending,
    output logic [31:0] invalid_frame_count,
    output logic crc_frame_valid,
    output logic crc_frame_error,
    output logic [31:0] crc_frame_value,
    output logic [31:0] crc_good_frames, crc_bad_frames, crc_aborted_frames
);
    a0_host_graphics_bridge_p46 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS), .ADDR_BITS(ADDR_BITS)
    ) bridge (
        .clk(clk), .rst_n(rst_n),
        .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_byte(rx_byte),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_byte(tx_byte),
        .scan_enable(scan_enable), .pixel_valid(pixel_valid),
        .pixel_ready(pixel_ready), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .pixel_color(pixel_color), .start_of_frame(start_of_frame),
        .end_of_line(end_of_line), .end_of_frame(end_of_frame),
        .frame_done(frame_done), .display_bank(display_bank),
        .render_bank(render_bank), .display_initialized(display_initialized),
        .render_initialized(render_initialized), .render_busy(render_busy),
        .swap_pending(swap_pending), .invalid_frame_count(invalid_frame_count)
    );
    a0_scanout_frame_guard_p47 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) guard (
        .clk(clk), .rst_n(rst_n),
        .stream_active(scan_enable && display_initialized),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_color(pixel_color),
        .start_of_frame(start_of_frame), .end_of_line(end_of_line),
        .end_of_frame(end_of_frame),
        .frame_valid(crc_frame_valid), .frame_error(crc_frame_error),
        .frame_crc32(crc_frame_value),
        .good_frame_count(crc_good_frames),
        .bad_frame_count(crc_bad_frames),
        .aborted_frame_count(crc_aborted_frames)
    );
endmodule
