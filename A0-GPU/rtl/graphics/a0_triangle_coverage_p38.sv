`timescale 1ns/1ps
// P136: raster P38 with incremental 36-bit edge functions.
// On triangle acceptance, compute edge values at pixel center (0.5,0.5).
// On each accepted X pixel step: edge += -2*dy. On scanline wrap:
// edge = row_start + 2*dx. Maintain exact top-left coverage and stall
// semantics of the frozen original 64-bit P38 oracle.
// Research RTL, not a production GPU rasterizer or board qualification.
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
    logic active;
    logic [15:0] scan_x, scan_y;
    logic signed [15:0] ax, ay, bx, by, cx, cy;
    logic signed [35:0] input_area;
    logic hit;

    logic signed [15:0] launch_bx, launch_by, launch_cx, launch_cy;
    logic signed [35:0] initial_e0, initial_e1, initial_e2;
    // Calculate both input winding orders in parallel. Do NOT feed
    // input_area -> vertex mux -> wide edge multipliers in one clock.
    logic signed [35:0] launch_e_ab, launch_e_bc, launch_e_ca;
    logic signed [35:0] launch_e_ac, launch_e_cb, launch_e_ba;
    logic signed [35:0] edge0, edge1, edge2;
    logic signed [35:0] row0, row1, row2;
    logic signed [17:0] step_x0, step_x1, step_x2;
    logic signed [17:0] step_y0, step_y1, step_y2;
    logic signed [17:0] launch_step_x0,launch_step_x1,launch_step_x2;
    logic signed [17:0] launch_step_y0,launch_step_y1,launch_step_y2;

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_WIDTH > 32767 || FRAME_HEIGHT < 1 || FRAME_HEIGHT > 32767)
            $fatal(1, "P136 P38 dimensions must be in 1..32767");
    end

    // P130 exact-width proof: dx/dy fit 17 bits, doubled distances fit
    // signed 18 bits, products signed 35 bits and difference signed 36 bits.
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
        top_left = (ey1 < ey0) || ((ey1 == ey0) && (ex1 > ex0));
    endfunction

    // Normalize the winding at launch before forming the three edge slopes.
    always_comb begin
        input_area = edge_at(x0, y0, x1, y1,
                             $signed(x2) * 17'sd2, $signed(y2) * 17'sd2);
        launch_bx = input_area < 0 ? x2 : x1;
        launch_by = input_area < 0 ? y2 : y1;
        launch_cx = input_area < 0 ? x1 : x2;
        launch_cy = input_area < 0 ? y1 : y2;

        // Parallel origin edge setup: only the final 36-bit mux is
        // dependent on signed input_area; neither multiplier is.
        launch_e_ab = edge_at(x0,y0,x1,y1,17'sd1,17'sd1);
        launch_e_bc = edge_at(x1,y1,x2,y2,17'sd1,17'sd1);
        launch_e_ca = edge_at(x2,y2,x0,y0,17'sd1,17'sd1);
        launch_e_ac = edge_at(x0,y0,x2,y2,17'sd1,17'sd1);
        launch_e_cb = edge_at(x2,y2,x1,y1,17'sd1,17'sd1);
        launch_e_ba = edge_at(x1,y1,x0,y0,17'sd1,17'sd1);
        initial_e0 = input_area < 0 ? launch_e_ac : launch_e_ab;
        initial_e1 = input_area < 0 ? launch_e_cb : launch_e_bc;
        initial_e2 = input_area < 0 ? launch_e_ba : launch_e_ca;

        // Move one pixel in X => sample_x2 += 2 and E -= 2*dy.
        // Move one row in Y at x=0 => sample_y2 += 2 and E += 2*dx.
        launch_step_x0 = -($signed(launch_by)-$signed(y0)) * 18'sd2;
        launch_step_x1 = -($signed(launch_cy)-$signed(launch_by)) * 18'sd2;
        launch_step_x2 = -($signed(y0)-$signed(launch_cy)) * 18'sd2;
        launch_step_y0 = ($signed(launch_bx)-$signed(x0)) * 18'sd2;
        launch_step_y1 = ($signed(launch_cx)-$signed(launch_bx)) * 18'sd2;
        launch_step_y2 = ($signed(x0)-$signed(launch_cx)) * 18'sd2;

        hit = ((edge0 > 0) || ((edge0 == 0) && top_left(ax, ay, bx, by))) &&
              ((edge1 > 0) || ((edge1 == 0) && top_left(bx, by, cx, cy))) &&
              ((edge2 > 0) || ((edge2 == 0) && top_left(cx, cy, ax, ay)));
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
            edge0 <= '0;edge1 <= '0;edge2 <= '0;
            row0 <= '0;row1 <= '0;row2 <= '0;
            step_x0 <= '0;step_x1 <= '0;step_x2 <= '0;
            step_y0 <= '0;step_y1 <= '0;step_y2 <= '0;
        end else begin
            done <= 1'b0;
            if (!active) begin
                if (tri_valid && tri_ready) begin
                    ax <= x0;
                    ay <= y0;
                    bx <= launch_bx;
                    by <= launch_by;
                    cx <= launch_cx;
                    cy <= launch_cy;
                    scan_x <= '0;
                    scan_y <= '0;
                    edge0 <= initial_e0;edge1 <= initial_e1;edge2 <= initial_e2;
                    row0 <= initial_e0;row1 <= initial_e1;row2 <= initial_e2;
                    step_x0 <= launch_step_x0;
                    step_x1 <= launch_step_x1;
                    step_x2 <= launch_step_x2;
                    step_y0 <= launch_step_y0;
                    step_y1 <= launch_step_y1;
                    step_y2 <= launch_step_y2;
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
                    row0 <= row0 + step_y0;
                    row1 <= row1 + step_y1;
                    row2 <= row2 + step_y2;
                    edge0 <= row0 + step_y0;
                    edge1 <= row1 + step_y1;
                    edge2 <= row2 + step_y2;
                end else begin
                    scan_x <= scan_x + 16'd1;
                    edge0 <= edge0 + step_x0;
                    edge1 <= edge1 + step_x1;
                    edge2 <= edge2 + step_x2;
                end
            end
        end
    end
endmodule
