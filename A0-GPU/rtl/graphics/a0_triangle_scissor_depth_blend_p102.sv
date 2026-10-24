`timescale 1ns/1ps
// P102 RESEARCH INTEGRATION: P38 raster -> P59 scissor -> P68 depth ->
// P70 RGB blend -> local framebuffer. One color and one depth per pixel.
// Not a physical VRAM, P43 command connection, PCIe device, or qualified RTL.
// Unsynthesized/unverified until a real HDL gate runs. Debug reads are
// asynchronous; storage may map to registers rather than block RAM.
module a0_triangle_scissor_depth_blend_p102 #(
    parameter int FRAME_WIDTH = 8,
    parameter int FRAME_HEIGHT = 8,
    parameter int PIXELS = FRAME_WIDTH * FRAME_HEIGHT,
    parameter int ADDR_BITS = PIXELS <= 1 ? 1 : $clog2(PIXELS)
)(
    input logic clk, rst_n,
    input logic clear_valid,
    output logic clear_ready,
    input logic [23:0] clear_color, clear_depth,
    output logic clear_done,
    input logic tri_valid,
    output logic tri_ready,
    input logic signed [15:0] x0,y0,x1,y1,x2,y2,
    input logic [23:0] tri_color, tri_depth,
    input logic [1:0] depth_compare_op,
    input logic depth_write, blend_enable,
    input logic [7:0] source_alpha,
    input logic scissor_enable,
    input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
    output logic tri_done,
    output logic initialized, busy,
    input logic [15:0] read_x, read_y,
    output logic read_valid,
    output logic [23:0] read_color, read_depth,
    output logic pixel_wrote
);
    logic [23:0] color_ram [0:PIXELS-1];
    logic [23:0] depth_ram [0:PIXELS-1];
    logic clearing;
    logic [ADDR_BITS-1:0] clear_index;
    logic [23:0] clear_color_q,clear_depth_q;
    logic [23:0] tri_color_q,tri_depth_q;
    logic [1:0] depth_op_q;
    logic depth_write_q,blend_enable_q,scissor_enable_q;
    logic [7:0] source_alpha_q;
    logic [15:0] scissor_x_q,scissor_y_q,scissor_w_q,scissor_h_q;
    logic raster_ready,raster_pixel_valid,raster_done;
    logic [15:0] raster_x,raster_y;
    logic [ADDR_BITS-1:0] raster_index;
    // P137: the P38 raster visits every framebuffer location in linear
    // row-major order, whether covered or uncovered. Track that index at
    // the same clock edge as the raster coordinate state instead of a
    // per-pixel (raster_y*FRAME_WIDTH)+raster_x combinational multiplier.
    // The engine hardwires pixel_ready=1: if backpressure is introduced,
    // update this counter only on actual P38 scan acceptance.
    logic [ADDR_BITS-1:0] scan_index_q;
    logic scissor_pass,depth_pass;
    logic [23:0] blended_color;
    logic write_pixel;

    assign clear_ready = rst_n && !clearing && raster_ready;
    assign tri_ready = rst_n && initialized && !clearing && !clear_valid && raster_ready;
    assign busy = clearing || !raster_ready;
    assign tri_done = rst_n && raster_done;
    assign raster_index = scan_index_q;
    always_ff @(posedge clk) begin
        if (!rst_n)
            scan_index_q <= '0;
        else if (tri_valid && tri_ready)
            // P38 simultaneously begins raster traversal at (0,0).
            scan_index_q <= '0;
        else if (!raster_ready) begin
            // P38 consumes exactly one scan coordinate per active clock
            // because pixel_ready is tied high at its instantiation.
            if (raster_x == FRAME_WIDTH - 1 && raster_y == FRAME_HEIGHT - 1)
                scan_index_q <= '0;
            else
                scan_index_q <= scan_index_q + 1'b1;
        end
    end

    a0_triangle_coverage_p38 #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)) raster(
      .clk(clk),.rst_n(rst_n),.tri_valid(tri_valid && tri_ready),.tri_ready(raster_ready),
      .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
      .pixel_valid(raster_pixel_valid),.pixel_ready(1'b1),
      .pixel_x(raster_x),.pixel_y(raster_y),.done(raster_done)
    );
    a0_p59_scissor_coverage scissor(
      .pixel_x(raster_x),.pixel_y(raster_y),.rect_x(scissor_x_q),
      .rect_y(scissor_y_q),.rect_width(scissor_w_q),.rect_height(scissor_h_q),
      .enable(scissor_enable_q),.covered(scissor_pass)
    );
    a0_p68_depth_compare depth_test(
      .incoming_depth(tri_depth_q),.stored_depth(depth_ram[raster_index]),
      .compare_op(depth_op_q),.candidate_valid(raster_pixel_valid && scissor_pass),
      .accept(depth_pass)
    );
    a0_p70_rgb_blend blend(
      .source_rgb(tri_color_q),.destination_rgb(color_ram[raster_index]),
      .source_alpha(source_alpha_q),.blend_enable(blend_enable_q),
      .output_rgb(blended_color)
    );
    assign write_pixel = rst_n && initialized && !clearing && raster_pixel_valid && depth_pass;
    always_comb begin
        read_valid = rst_n && initialized && read_x<FRAME_WIDTH && read_y<FRAME_HEIGHT;
        read_color = '0;
        read_depth = '0;
        if (read_valid) begin
            read_color = color_ram[(read_y*FRAME_WIDTH)+read_x];
            read_depth = depth_ram[(read_y*FRAME_WIDTH)+read_x];
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clearing <= 1'b0;
            clear_index <= '0;
            clear_color_q <= '0; clear_depth_q <= '0;
            initialized <= 1'b0;
            clear_done <= 1'b0;
            pixel_wrote <= 1'b0;
            tri_color_q <= '0; tri_depth_q <= '0; depth_op_q <= '0;
            depth_write_q <= 1'b0; blend_enable_q <= 1'b0;
            source_alpha_q <= '0;
            scissor_enable_q <= 1'b0;
            scissor_x_q <= '0;scissor_y_q <= '0;scissor_w_q <= '0;scissor_h_q <= '0;
        end else begin
            clear_done <= 1'b0;
            pixel_wrote <= 1'b0;
            if (clearing) begin
                color_ram[clear_index] <= clear_color_q;
                depth_ram[clear_index] <= clear_depth_q;
                if (clear_index==PIXELS-1) begin
                    clearing <= 1'b0;
                    initialized <= 1'b1;
                    clear_done <= 1'b1;
                    clear_index <= '0;
                end else clear_index <= clear_index + 1'b1;
            end else if (clear_valid && clear_ready) begin
                clearing <= 1'b1;
                initialized <= 1'b0;
                clear_color_q <= clear_color;
                clear_depth_q <= clear_depth;
                clear_index <= '0;
            end else if (tri_valid && tri_ready) begin
                // Snapshot all triangle state on acceptance: changing input
                // registers during an in-flight raster cannot change output.
                tri_color_q <= tri_color;
                tri_depth_q <= tri_depth;
                depth_op_q <= depth_compare_op;
                depth_write_q <= depth_write;
                blend_enable_q <= blend_enable;
                source_alpha_q <= source_alpha;
                scissor_enable_q <= scissor_enable;
                scissor_x_q <= scissor_x;scissor_y_q <= scissor_y;
                scissor_w_q <= scissor_w;scissor_h_q <= scissor_h;
            end
            if (write_pixel) begin
                color_ram[raster_index] <= blended_color;
                if (depth_write_q) depth_ram[raster_index] <= tri_depth_q;
                pixel_wrote <= 1'b1;
            end
        end
    end
    initial begin
        if (FRAME_WIDTH<1 || FRAME_WIDTH>32767 || FRAME_HEIGHT<1 || FRAME_HEIGHT>32767 ||
            PIXELS != FRAME_WIDTH*FRAME_HEIGHT || PIXELS>65536 ||
            ADDR_BITS < (PIXELS<=1 ? 1 : $clog2(PIXELS)))
            $fatal(1,"P102 invalid framebuffer dimensions");
    end
endmodule
