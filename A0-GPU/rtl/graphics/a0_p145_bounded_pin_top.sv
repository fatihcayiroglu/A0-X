`timescale 1ns/1ps
// P145 FPGA-RESEARCH bounded pin wrapper: same complete dual raster/RMW
// core, but six exposed triangle vertices use signed 8-bit coordinates.
// This removes 48 unneeded physical prototype pins vs full 16-bit ports
// while preserving sign-extended coordinates and all 48-bit pixel paths.
// 4x4,7x5,8x8 directed RTL scenes fit within signed 8-bit vertices.
// NOT a universal 16-bit board API or production command transport.
module a0_p145_bounded_pin_top #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4
)(
  input logic clk,rst_n,
  input logic clear_valid,
  output logic clear_ready,clear_done,
  input logic [23:0] clear_color,clear_depth,
  input logic tri_valid,
  output logic tri_ready,tri_done,
  input logic signed [7:0] x0,y0,x1,y1,x2,y2,
  input logic [23:0] tri_color,tri_depth,
  input logic [1:0] depth_compare_op,
  input logic depth_write,blend_enable,
  input logic [7:0] source_alpha,
  input logic scissor_enable,
  input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
  output logic initialized,busy,fault,
  output logic [1:0] pixel_writes,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  a0_p145_dual_raster_depth_blend_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) full_raster_core(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid),.clear_ready(clear_ready),
    .clear_color(clear_color),.clear_depth(clear_depth),
    .clear_done(clear_done),
    .tri_valid(tri_valid),.tri_ready(tri_ready),.tri_done(tri_done),
    .x0({{8{x0[7]}},x0}),.y0({{8{y0[7]}},y0}),
    .x1({{8{x1[7]}},x1}),.y1({{8{y1[7]}},y1}),
    .x2({{8{x2[7]}},x2}),.y2({{8{y2[7]}},y2}),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .initialized(initialized),.busy(busy),.fault(fault),
    .pixel_writes(pixel_writes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );
endmodule
