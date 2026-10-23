`timescale 1ns/1ps
// A0-X P39 EXPERIMENTAL triangle-to-framebuffer vertical slice.
// Connects the P38 raster-coverage stream to a single local RGB888 framebuffer.
// Not connected to production CU, MMU, DMA, PCIe, or display scanout.
// A CLEAR transaction is required after reset before any triangle is accepted.
// Framebuffer reads are asynchronous for research/debug only; not a display
// timing interface. Writes during reads may tear; no double buffering.
module a0_triangle_framebuffer_p39 #(
    parameter int FRAME_WIDTH  = 8,
    parameter int FRAME_HEIGHT = 8
)(
    input logic clk,
    input logic rst_n,
    input logic clear_valid,
    output logic clear_ready,
    input logic [23:0] clear_color,
    output logic clear_done,
    input logic tri_valid,
    output logic tri_ready,
    input logic signed [15:0] x0, y0, x1, y1, x2, y2,
    input logic [23:0] tri_color,
    output logic tri_done,
    input logic [15:0] read_x, read_y,
    output logic [23:0] read_color,
    output logic initialized,
    output logic busy
);
    localparam int PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam int ADDR_BITS = PIXELS <= 1 ? 1 : $clog2(PIXELS);

    logic [23:0] framebuffer [0:PIXELS-1];
    logic clear_active;
    logic [ADDR_BITS-1:0] clear_index;
    logic [23:0] clear_color_q;
    logic [23:0] triangle_color_q;

    logic raster_tri_valid, raster_tri_ready;
    logic pixel_valid, raster_done;
    logic [15:0] pixel_x, pixel_y;

    // Priority when both commands are offered on an idle cycle: CLEAR wins.
    // tri_ready=0 prevents a second, accidental simultaneous acceptance.
    assign clear_ready = rst_n && !clear_active && raster_tri_ready;
    assign tri_ready = rst_n && initialized && !clear_active &&
                       raster_tri_ready && !clear_valid;
    assign raster_tri_valid = tri_valid && tri_ready;
    assign tri_done = rst_n && raster_done;
    assign busy = clear_active || !raster_tri_ready;

    a0_triangle_coverage_p38 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) raster (
        .clk(clk), .rst_n(rst_n),
        .tri_valid(raster_tri_valid), .tri_ready(raster_tri_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .pixel_valid(pixel_valid), .pixel_ready(1'b1),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .done(raster_done)
    );

    // No SRAM contents assumed across reset. Only initialized readout allowed.
    always_comb begin
        read_color = 24'h000000;
        if (rst_n && initialized && int'(read_x) < FRAME_WIDTH && int'(read_y) < FRAME_HEIGHT)
            read_color = framebuffer[(int'(read_y) * FRAME_WIDTH) + int'(read_x)];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clear_active <= 1'b0;
            clear_index <= '0;
            clear_color_q <= '0;
            triangle_color_q <= '0;
            clear_done <= 1'b0;
            initialized <= 1'b0;
        end else begin
            clear_done <= 1'b0;
            if (clear_active) begin
                framebuffer[clear_index] <= clear_color_q;
                if (int'(clear_index) == PIXELS - 1) begin
                    clear_active <= 1'b0;
                    initialized <= 1'b1;
                    clear_done <= 1'b1;
                    clear_index <= '0;
                end else begin
                    clear_index <= clear_index + 1'b1;
                end
            end else if (clear_valid && clear_ready) begin
                // No simultaneous raster writes: raster is guaranteed idle.
                clear_active <= 1'b1;
                initialized <= 1'b0;
                clear_color_q <= clear_color;
                clear_index <= '0;
            end else if (raster_tri_valid) begin
                triangle_color_q <= tri_color;
            end
            if (pixel_valid && !clear_active) begin
                framebuffer[(int'(pixel_y) * FRAME_WIDTH) + int'(pixel_x)] <= triangle_color_q;
            end
        end
    end

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_WIDTH > 32767 ||
            FRAME_HEIGHT < 1 || FRAME_HEIGHT > 32767 ||
            PIXELS < 1 || PIXELS > 65536)
            $fatal(1, "P39 supported framebuffer size: 1..65536 pixels, signed-16 dimensions");
    end
endmodule
