`timescale 1ns/1ps
// A0-X P40 RESEARCH SCANOUT — simulation-oriented RGB888 pixel stream.
// Reads from P39's asynchronous debug framebuffer port. This is NOT a VGA,
// HDMI, DisplayPort, PHY, pixel-clock or blanking-timing implementation.
// Transfer only on (pixel_valid && pixel_ready). Outputs (data and marker
// fields) remain stable throughout backpressure. A disabled / uninitialized
// framebuffer aborts the partial frame and restarts from (0,0).
// Concurrent draw writes can cause tearing; frame buffering is not provided.
module a0_frame_scanout_p40 #(
    parameter int FRAME_WIDTH  = 8,
    parameter int FRAME_HEIGHT = 8
) (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic framebuffer_initialized,
    output logic [15:0] read_x,
    output logic [15:0] read_y,
    input  logic [23:0] read_color,
    output logic pixel_valid,
    input  logic pixel_ready,
    output logic [15:0] pixel_x,
    output logic [15:0] pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame,
    output logic end_of_line,
    output logic end_of_frame,
    output logic frame_done
);
    logic [15:0] fetch_x, fetch_y;
    logic valid_q;
    logic [15:0] x_q, y_q;
    logic [23:0] color_q;
    logic sof_q, eol_q, eof_q;
    logic running;
    logic accept;

    assign running = rst_n && enable && framebuffer_initialized;
    assign read_x = fetch_x;
    assign read_y = fetch_y;
    assign pixel_valid = running && valid_q;
    assign pixel_x = x_q;
    assign pixel_y = y_q;
    assign pixel_color = color_q;
    // Markers only valid when pixel_valid is true.
    assign start_of_frame = pixel_valid && sof_q;
    assign end_of_line = pixel_valid && eol_q;
    assign end_of_frame = pixel_valid && eof_q;
    assign accept = pixel_valid && pixel_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fetch_x <= '0;
            fetch_y <= '0;
            valid_q <= 1'b0;
            x_q <= '0;
            y_q <= '0;
            color_q <= '0;
            sof_q <= 1'b0;
            eol_q <= 1'b0;
            eof_q <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= accept && eof_q;
            if (!running) begin
                fetch_x <= '0;
                fetch_y <= '0;
                valid_q <= 1'b0;
                x_q <= '0;
                y_q <= '0;
                color_q <= '0;
                sof_q <= 1'b0;
                eol_q <= 1'b0;
                eof_q <= 1'b0;
            end else if (!valid_q || pixel_ready) begin
                // Asynchronous P39 read data is sampled exactly once per
                // output entry, so downstream stalls do not change it.
                valid_q <= 1'b1;
                x_q <= fetch_x;
                y_q <= fetch_y;
                color_q <= read_color;
                sof_q <= (fetch_x == 16'd0 && fetch_y == 16'd0);
                eol_q <= (int'(fetch_x) == FRAME_WIDTH - 1);
                eof_q <= (int'(fetch_x) == FRAME_WIDTH - 1 &&
                          int'(fetch_y) == FRAME_HEIGHT - 1);
                if (int'(fetch_x) == FRAME_WIDTH - 1) begin
                    fetch_x <= '0;
                    if (int'(fetch_y) == FRAME_HEIGHT - 1)
                        fetch_y <= '0;
                    else
                        fetch_y <= fetch_y + 16'd1;
                end else begin
                    fetch_x <= fetch_x + 16'd1;
                end
            end
        end
    end

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_WIDTH > 32767 ||
            FRAME_HEIGHT < 1 || FRAME_HEIGHT > 32767 ||
            FRAME_WIDTH * FRAME_HEIGHT > 65536)
            $fatal(1, "P40 accepts 1..65536 pixels with signed-16 dimensions");
    end
endmodule
