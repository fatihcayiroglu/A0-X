`timescale 1ns/1ps
// P46 development vertical slice: P44 bytes -> P45 RX -> P43/P42 display
// -> P46 result bytes. NO physical host bus, PCIe, DMA, driver, or P37 VRAM.
// The result frame's cycles field is local elapsed bridge clocks from command
// acceptance through command completion acceptance; it is NOT P44 model cycles.
// Synchronous active-low rst_n must reset all instantiated blocks together.
module a0_host_graphics_bridge_p46 #(
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
    output logic [31:0] invalid_frame_count
);
    logic cmd_valid, cmd_ready;
    logic [1:0] cmd_opcode;
    logic [15:0] cmd_tag;
    logic [23:0] cmd_color;
    logic signed [15:0] cmd_x0,cmd_y0,cmd_x1,cmd_y1,cmd_x2,cmd_y2;
    logic completion_valid, completion_ready, completion_error;
    logic [15:0] completion_tag;
    logic command_busy;
    logic pending_cycle_q;
    logic [31:0] elapsed_q;

    a0_host_command_rx_p45 receiver (
        .clk(clk), .rst_n(rst_n),
        .in_valid(rx_valid), .in_ready(rx_ready), .in_byte(rx_byte),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode), .cmd_tag(cmd_tag), .cmd_color(cmd_color),
        .cmd_x0(cmd_x0), .cmd_y0(cmd_y0), .cmd_x1(cmd_x1),
        .cmd_y1(cmd_y1), .cmd_x2(cmd_x2), .cmd_y2(cmd_y2),
        .invalid_frame_count(invalid_frame_count)
    );

    a0_command_triangle_sync_display_p43 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS), .ADDR_BITS(ADDR_BITS), .TAG_BITS(16)
    ) graphics (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode), .cmd_tag(cmd_tag), .cmd_color(cmd_color),
        .cmd_x0(cmd_x0), .cmd_y0(cmd_y0), .cmd_x1(cmd_x1),
        .cmd_y1(cmd_y1), .cmd_x2(cmd_x2), .cmd_y2(cmd_y2),
        .completion_valid(completion_valid), .completion_ready(completion_ready),
        .completion_tag(completion_tag), .completion_error(completion_error),
        .command_busy(command_busy),
        .scan_enable(scan_enable), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_color(pixel_color),
        .start_of_frame(start_of_frame), .end_of_line(end_of_line),
        .end_of_frame(end_of_frame), .frame_done(frame_done),
        .display_bank(display_bank), .render_bank(render_bank),
        .display_initialized(display_initialized), .render_initialized(render_initialized),
        .render_busy(render_busy), .swap_pending(swap_pending)
    );

    a0_host_result_tx_p46 sender (
        .clk(clk), .rst_n(rst_n),
        .result_valid(completion_valid), .result_ready(completion_ready),
        .result_tag(completion_tag), .result_error(completion_error),
        .result_cycles(elapsed_q),
        .out_valid(tx_valid), .out_ready(tx_ready), .out_byte(tx_byte)
    );

    // Tracks one P43 command at a time. Saturates rather than wrapping if
    // the host keeps the TX path blocked longer than 2^32 device clocks.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pending_cycle_q <= 1'b0;
            elapsed_q <= 32'd0;
        end else if (cmd_valid && cmd_ready) begin
            pending_cycle_q <= 1'b1;
            elapsed_q <= 32'd0;
        end else if (completion_valid && completion_ready) begin
            pending_cycle_q <= 1'b0;
        end else if (pending_cycle_q && elapsed_q != 32'hffffffff) begin
            elapsed_q <= elapsed_q + 32'd1;
        end
    end
endmodule
