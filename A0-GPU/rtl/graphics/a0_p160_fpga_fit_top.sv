`timescale 1ns/1ps
// P160 limited-interface FPGA research fit, not a complete host bus.
// P160's full 439-bit parallel trial interface exceeds ECP5 CABGA756's
// 365 routable I/O cells. Retain real texel writes, triangle coords,
// repeat/clamp, signed UV offset, shader opcode/operand and host reads;
// select fixed framebuffer/depth/alpha controls to reduce package pins.
// A future packed command bus is required for full software programmability.
module a0_p160_fpga_fit_top(
  input logic clk,rst_n,
  input logic tex_write_valid,
  output logic tex_write_ready,
  input logic [3:0] tex_write_x,tex_write_y,
  input logic [31:0] tex_write_rgba,
  input logic clear_valid,
  output logic clear_ready,clear_done,
  input logic tri_valid,
  output logic tri_ready,tri_done,
  input logic signed [15:0] x0,y0,x1,y1,x2,y2,
  input logic signed [15:0] uv_offset_u,uv_offset_v,
  input logic sample_repeat,
  input logic [2:0] shader_opcode,
  input logic [31:0] shader_operand_b,
  output logic initialized,busy,fault,
  output logic [15:0] shaded_pixels,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  a0_p160_textured_fragment_trial #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) core(
    .clk(clk),.rst_n(rst_n),
    .tex_write_valid(tex_write_valid),.tex_write_ready(tex_write_ready),
    .tex_write_x(tex_write_x),.tex_write_y(tex_write_y),
    .tex_write_rgba(tex_write_rgba),
    .clear_valid(clear_valid),.clear_ready(clear_ready),
    .clear_done(clear_done),
    .clear_color(24'h112233),.clear_depth(24'hffffff),
    .tri_valid(tri_valid),.tri_ready(tri_ready),.tri_done(tri_done),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_depth(24'h000040),.depth_compare_op(2'd1),
    .depth_write(1'b1),.blend_enable(1'b0),.source_alpha(8'hff),
    .uv_offset_u(uv_offset_u),.uv_offset_v(uv_offset_v),
    .sample_repeat(sample_repeat),
    .shader_opcode(shader_opcode),.shader_operand_b(shader_operand_b),
    .shader_alpha(8'd128),.shader_lane_mask(4'hf),
    .initialized(initialized),.busy(busy),.fault(fault),
    .shaded_pixels(shaded_pixels),.last_shaded_rgb(),.pixel_writes(),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );
endmodule
