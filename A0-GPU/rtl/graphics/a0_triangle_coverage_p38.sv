`timescale 1ns/1ps
// A0-X P38 EXPERIMENTAL: integer-coordinate, pixel-center triangle coverage.
// Standalone research RTL, not integrated into production command/graphics paths.
// Positive screen-space area is normalized, and a y-down top-left fill convention
// is applied to avoid double-shading pixels on shared edges.
// One framebuffer location examined per un-stalled clock; emitting pixels is
// suppressed for uncovered locations. Not a throughput-optimized rasterizer.
module a0_triangle_coverage_p38 #(
    parameter int FRAME_WIDTH  = 8,
    parameter int FRAME_HEIGHT = 8
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               tri_valid,
    output logic               tri_ready,
    input  logic signed [15:0] x0,
    input  logic signed [15:0] y0,
    input  logic signed [15:0] x1,
    input  logic signed [15:0] y1,
    input  logic signed [15:0] x2,
    input  logic signed [15:0] y2,
    output logic               pixel_valid,
    input  logic               pixel_ready,
    output logic        [15:0] pixel_x,
    output logic        [15:0] pixel_y,
    output logic               done
);
    // P130 exact-width optimization: under FRAME_WIDTH/HEIGHT <= 32767 and
    // signed-16 vertices, dx/dy fit signed 17 bits, rx/ry signed 18 bits,
    // each product signed 35 bits, their difference signed 36 bits. This
    // removes unnecessary 64x64 combinational multiplies without truncation.
    // End-to-end equivalence with the original 64-bit P38 is gated by CI.
    logic active;
    logic [15:0] scan_x, scan_y;
    logic signed [15:0] ax, ay, bx, by, cx, cy;
    logic signed [35:0] input_area;
    logic signed [35:0] e0, e1, e2;
    logic signed [16:0] sample_x2, sample_y2;
    logic hit;
    initial begin
        if (FRAME_WIDTH < 1 || FRAME_WIDTH > 32767 || FRAME_HEIGHT < 1 || FRAME_HEIGHT > 32767)
            $fatal(1, "P130 P38 dimensions must be in 1..32767");
    end

    function automatic logic signed [35:0] edge_at (
        input logic signed [15:0] ex0, ey0, ex1, ey1,
        input logic signed [16:0] px2, py2
    );
        logic signed [16:0] dx, dy;
        logic signed [17:0] rx, ry;
        logic signed [34:0] product_x, product_y;
        begin
            dx = $signed(ex1) - $signed(ex0);
            dy = $signed(ey1) - $signed(ey0);
            rx = $signed(px2) - ($signed(ex0) * 18'sd2);
            ry = $signed(py2) - ($signed(ey0) * 18'sd2);
            product_x = dx * ry;
            product_y = dy * rx;
            edge_at = $signed(product_x) - $signed(product_y);
        end
    endfunction

    function automatic logic top_left (
        input logic signed [15:0] ex0, ey0, ex1, ey1
    );
        // For positive determinant in a screen-coordinate system with Y down.
        top_left = (ey1 < ey0) || ((ey1 == ey0) && (ex1 > ex0));
    endfunction

    always_comb begin
        input_area = edge_at(x0, y0, x1, y1,
                             $signed(x2) * 17'sd2, $signed(y2) * 17'sd2);
        sample_x2 = ($signed({1'b0, scan_x}) * 17'sd2) + 17'sd1;
        sample_y2 = ($signed({1'b0, scan_y}) * 17'sd2) + 17'sd1;
        e0 = edge_at(ax, ay, bx, by, sample_x2, sample_y2);
        e1 = edge_at(bx, by, cx, cy, sample_x2, sample_y2);
        e2 = edge_at(cx, cy, ax, ay, sample_x2, sample_y2);
        hit = ((e0 > 0) || ((e0 == 0) && top_left(ax, ay, bx, by))) &&
              ((e1 > 0) || ((e1 == 0) && top_left(bx, by, cx, cy))) &&
              ((e2 > 0) || ((e2 == 0) && top_left(cx, cy, ax, ay)));
        tri_ready   = rst_n && !active;
        pixel_valid = rst_n && active && hit;
        pixel_x     = scan_x;
        pixel_y     = scan_y;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            scan_x <= '0;
            scan_y <= '0;
            ax <= '0; ay <= '0;
            bx <= '0; by <= '0;
            cx <= '0; cy <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!active) begin
                if (tri_valid && tri_ready) begin
                    ax <= x0;
                    ay <= y0;
                    if (input_area < 0) begin
                        // Normalize either original winding to positive area.
                        bx <= x2; by <= y2;
                        cx <= x1; cy <= y1;
                    end else begin
                        bx <= x1; by <= y1;
                        cx <= x2; cy <= y2;
                    end
                    scan_x <= '0;
                    scan_y <= '0;
                    if (input_area == 0) begin
                        done <= 1'b1;
                    end else begin
                        active <= 1'b1;
                    end
                end
            end else if (!pixel_valid || pixel_ready) begin
                if ((scan_x == FRAME_WIDTH - 1) &&
                    (scan_y == FRAME_HEIGHT - 1)) begin
                    active <= 1'b0;
                    done <= 1'b1;
                end else if (scan_x == FRAME_WIDTH - 1) begin
                    scan_x <= '0;
                    scan_y <= scan_y + 16'd1;
                end else begin
                    scan_x <= scan_x + 16'd1;
                end
            end
        end
    end
endmodule