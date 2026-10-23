`timescale 1ns/1ps
// P43 standalone command -> P42 back-buffer render -> synchronous scanout.
// Not connected to the P37 production memory subsystem or host bus.
module a0_command_triangle_sync_display_p43 #(
    parameter int FRAME_WIDTH=8,
    parameter int FRAME_HEIGHT=8,
    parameter int PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter int ADDR_BITS=(PIXELS <= 1 ? 1 : $clog2(PIXELS)),
    parameter int TAG_BITS=16
)(
    input logic clk, rst_n,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [1:0] cmd_opcode,
    input logic [TAG_BITS-1:0] cmd_tag,
    input logic [23:0] cmd_color,
    input logic signed [15:0] cmd_x0, cmd_y0, cmd_x1, cmd_y1, cmd_x2, cmd_y2,
    output logic completion_valid,
    input logic completion_ready,
    output logic [TAG_BITS-1:0] completion_tag,
    output logic completion_error,
    output logic command_busy,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x, pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame, end_of_line, end_of_frame, frame_done,
    output logic display_bank, render_bank, display_initialized,
    output logic render_initialized, render_busy,
    output logic swap_pending
);
    logic clear_valid, clear_ready, clear_done;
    logic tri_valid, tri_ready, tri_done;
    logic swap_valid, swap_ready, swap_done;
    logic [23:0] clear_color, tri_color;
    logic signed [15:0] x0,y0,x1,y1,x2,y2;
    a0_graphics_command_frontend_p43 #(.TAG_BITS(TAG_BITS)) frontend (
        .clk(clk), .rst_n(rst_n), .render_initialized(render_initialized),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode), .cmd_tag(cmd_tag), .cmd_color(cmd_color),
        .cmd_x0(cmd_x0), .cmd_y0(cmd_y0), .cmd_x1(cmd_x1), .cmd_y1(cmd_y1),
        .cmd_x2(cmd_x2), .cmd_y2(cmd_y2),
        .completion_valid(completion_valid), .completion_ready(completion_ready),
        .completion_tag(completion_tag), .completion_error(completion_error), .busy(command_busy),
        .clear_valid(clear_valid), .clear_ready(clear_ready), .clear_done(clear_done),
        .clear_color(clear_color), .tri_valid(tri_valid), .tri_ready(tri_ready),
        .tri_done(tri_done), .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .tri_color(tri_color), .swap_valid(swap_valid), .swap_ready(swap_ready),
        .swap_done(swap_done)
    );
    a0_triangle_double_buffer_sync_display_p42 #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS),.ADDR_BITS(ADDR_BITS)
    ) display (
        .clk(clk), .rst_n(rst_n),
        .clear_valid(clear_valid),.clear_ready(clear_ready),.clear_color(clear_color),.clear_done(clear_done),
        .tri_valid(tri_valid),.tri_ready(tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),.tri_done(tri_done),
        .render_initialized(render_initialized),.render_busy(render_busy),
        .swap_valid(swap_valid),.swap_ready(swap_ready),.swap_pending(swap_pending),.swap_done(swap_done),
        .display_bank(display_bank),.render_bank(render_bank),.display_initialized(display_initialized),
        .scan_enable(scan_enable),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),.frame_done(frame_done)
    );
endmodule
