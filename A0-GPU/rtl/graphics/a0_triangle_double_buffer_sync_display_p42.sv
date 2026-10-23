`timescale 1ns/1ps
// A0-X P42 EXPERIMENTAL end-to-end triangle -> synchronous RAM -> scanout.
// Replaces asynchronous P39/P40 framebuffer reads in an independent wrapper.
// Neither an external VRAM controller nor a physical HDMI/DP interface.
module a0_triangle_double_buffer_sync_display_p42 #(
    parameter int FRAME_WIDTH = 8,
    parameter int FRAME_HEIGHT = 8,
    parameter int PIXELS = FRAME_WIDTH * FRAME_HEIGHT,
    parameter int ADDR_BITS = (PIXELS <= 1 ? 1 : $clog2(PIXELS))
)(
    input logic clk, rst_n,
    input logic clear_valid,
    output logic clear_ready,
    input logic [23:0] clear_color,
    output logic clear_done,
    input logic tri_valid,
    output logic tri_ready,
    input logic signed [15:0] x0, y0, x1, y1, x2, y2,
    input logic [23:0] tri_color,
    output logic tri_done,
    output logic render_initialized, render_busy,
    input logic swap_valid,
    output logic swap_ready, swap_pending, swap_done,
    output logic display_bank, render_bank, display_initialized,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x, pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame, end_of_line, end_of_frame, frame_done
);
    logic display_bank_q, swap_pending_q;
    logic [1:0] initialized, ram_busy, ram_clear_ready, ram_clear_done;
    logic [1:0] ram_write_ready, ram_read_valid;
    logic [23:0] ram_read_data [0:1];
    logic ram_read_en;
    logic [ADDR_BITS-1:0] ram_read_addr;
    logic [ADDR_BITS-1:0] raster_addr;
    logic raster_ready, raster_pixel_valid, raster_pixel_ready, raster_done;
    logic [15:0] raster_x, raster_y;
    logic [23:0] tri_color_q;
    logic swap_accept, swap_commit, scan_active;
    logic [23:0] selected_read_data;
    logic selected_read_valid;

    assign display_bank = display_bank_q;
    assign render_bank = ~display_bank_q;
    assign display_initialized = initialized[display_bank_q];
    assign render_initialized = initialized[~display_bank_q];
    assign render_busy = ram_busy[~display_bank_q] || !raster_ready;
    assign clear_ready = rst_n && !swap_pending_q && raster_ready &&
                         ram_clear_ready[~display_bank_q];
    assign clear_done = ram_clear_done[~display_bank_q];
    assign tri_ready = rst_n && !swap_pending_q && !clear_valid &&
                       render_initialized && !ram_busy[~display_bank_q] && raster_ready;
    assign tri_done = rst_n && raster_done;
    assign swap_ready = rst_n && !swap_pending_q && !render_busy &&
                        render_initialized && !clear_valid && !tri_valid;
    assign swap_accept = swap_valid && swap_ready;
    assign swap_pending = swap_pending_q;
    assign swap_commit = rst_n && swap_pending_q &&
                         (!scan_enable || !display_initialized || frame_done);
    assign scan_active = scan_enable && !swap_commit;

    a0_triangle_coverage_p38 #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)) raster (
        .clk(clk), .rst_n(rst_n),
        .tri_valid(tri_valid && tri_ready), .tri_ready(raster_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .pixel_valid(raster_pixel_valid), .pixel_ready(raster_pixel_ready),
        .pixel_x(raster_x), .pixel_y(raster_y), .done(raster_done)
    );
    // The triangle color is captured at command acceptance and stays constant
    // until the raster has fully emitted all its pixels.
    always_ff @(posedge clk) begin
        if (!rst_n) tri_color_q <= '0;
        else if (tri_valid && tri_ready) tri_color_q <= tri_color;
    end
    assign raster_addr = ADDR_BITS'((int'(raster_y) * FRAME_WIDTH) + int'(raster_x));
    assign raster_pixel_ready = ram_write_ready[~display_bank_q];

    genvar g;
    generate
        for (g=0; g<2; g=g+1) begin : gen_bank
            wire own_back = (render_bank == 1'(g));
            wire own_front = (display_bank == 1'(g));
            a0_sync_frame_ram_p42 #(.PIXELS(PIXELS), .ADDR_BITS(ADDR_BITS)) ram (
                .clk(clk), .rst_n(rst_n),
                .clear_valid(clear_valid && clear_ready && own_back),
                .clear_ready(ram_clear_ready[g]), .clear_color(clear_color),
                .clear_done(ram_clear_done[g]), .busy(ram_busy[g]),
                .initialized(initialized[g]),
                .write_valid(raster_pixel_valid && raster_pixel_ready && own_back),
                .write_ready(ram_write_ready[g]), .write_addr(raster_addr),
                .write_color(tri_color_q),
                .read_en(ram_read_en && own_front), .read_addr(ram_read_addr),
                .read_valid(ram_read_valid[g]), .read_data(ram_read_data[g])
            );
        end
    endgenerate

    assign selected_read_valid = ram_read_valid[display_bank_q];
    assign selected_read_data = ram_read_data[display_bank_q];
    a0_sync_frame_scanout_p42 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS), .ADDR_BITS(ADDR_BITS)
    ) scanout (
        .clk(clk), .rst_n(rst_n), .enable(scan_active),
        .framebuffer_initialized(display_initialized),
        .read_en(ram_read_en), .read_addr(ram_read_addr),
        .read_valid(selected_read_valid), .read_data(selected_read_data),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_color(pixel_color),
        .start_of_frame(start_of_frame), .end_of_line(end_of_line),
        .end_of_frame(end_of_frame), .frame_done(frame_done)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            display_bank_q <= 1'b0;
            swap_pending_q <= 1'b0;
            swap_done <= 1'b0;
        end else begin
            swap_done <= 1'b0;
            if (swap_commit) begin
                display_bank_q <= ~display_bank_q;
                swap_pending_q <= 1'b0;
                swap_done <= 1'b1;
            end else if (swap_accept) begin
                swap_pending_q <= 1'b1;
            end
        end
    end

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_HEIGHT < 1 || FRAME_WIDTH > 32767 ||
            FRAME_HEIGHT > 32767 || PIXELS > 65536)
            $fatal(1, "P42 unsupported display geometry");
    end
endmodule
