`timescale 1ns/1ps
// P40 thin integration bridge: P38 rasterizer -> P39 RGB888 framebuffer ->
// P40 buffered scanout stream. No production GPU/CU/driver bus integration.
module a0_triangle_display_p40 #(
    parameter int FRAME_WIDTH  = 8,
    parameter int FRAME_HEIGHT = 8
)(
    input logic clk, rst_n,
    input logic clear_valid,
    output logic clear_ready,
    input logic [23:0] clear_color,
    output logic clear_done,
    input logic tri_valid,
    output logic tri_ready,
    input logic signed [15:0] x0,y0,x1,y1,x2,y2,
    input logic [23:0] tri_color,
    output logic tri_done,
    output logic initialized, busy,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x, pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame, end_of_line, end_of_frame,
    output logic frame_done
);
    logic [15:0] scan_read_x, scan_read_y;
    logic [23:0] scan_read_color;

    a0_triangle_framebuffer_p39 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) fb (
        .clk(clk), .rst_n(rst_n),
        .clear_valid(clear_valid), .clear_ready(clear_ready),
        .clear_color(clear_color), .clear_done(clear_done),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .tri_color(tri_color), .tri_done(tri_done),
        .read_x(scan_read_x), .read_y(scan_read_y),
        .read_color(scan_read_color),
        .initialized(initialized), .busy(busy)
    );

    a0_frame_scanout_p40 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) scan (
        .clk(clk), .rst_n(rst_n), .enable(scan_enable),
        .framebuffer_initialized(initialized),
        .read_x(scan_read_x), .read_y(scan_read_y),
        .read_color(scan_read_color),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_color(pixel_color),
        .start_of_frame(start_of_frame), .end_of_line(end_of_line),
        .end_of_frame(end_of_frame), .frame_done(frame_done)
    );
endmodule
