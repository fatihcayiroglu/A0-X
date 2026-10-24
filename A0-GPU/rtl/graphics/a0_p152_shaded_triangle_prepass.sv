`timescale 1ns/1ps
// P152 EXPERIMENTAL shader prepass: execute a real P151 UNORM program
// before launching a triangle on P146/P145 real dual-bank BRAM raster.
// Shader result register selects one flat RGBA colour for the entire
// triangle; this is NOT a per-fragment interpolated programmable shader.
module a0_p152_shaded_triangle_prepass #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
)(
  input logic clk,rst_n,
  input logic clear_valid,
  output logic clear_ready,clear_done,
  input logic [23:0] clear_color,clear_depth,
  input logic reg_write_valid,
  input logic [2:0] reg_write_index,
  input logic [31:0] reg_write_data,
  input logic insn_write_valid,
  input logic [3:0] insn_write_index,
  input logic [23:0] insn_write_data,
  input logic shaded_tri_valid,
  output logic shaded_tri_ready,shaded_tri_done,
  input logic [4:0] shader_length,
  input logic [2:0] color_result_reg,
  input logic signed [15:0] x0,y0,x1,y1,x2,y2,
  input logic [23:0] tri_depth,
  input logic [1:0] depth_compare_op,
  input logic depth_write,blend_enable,
  input logic [7:0] source_alpha,
  input logic scissor_enable,
  input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
  output logic initialized,busy,fault,
  output logic [4:0] shader_retired,
  output logic [1:0] pixel_writes,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  localparam logic [2:0] IDLE=0,SHADE=1,DRAW_ISSUE=2,DRAW_WAIT=3,FAILED=4;
  logic [2:0] state_q;
  logic signed [15:0] ax,ay,bx,by,cx,cy;
  logic [23:0] depth_q,color_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_q,scissor_q;
  logic [7:0] alpha_q;
  logic [15:0] sx_q,sy_q,sw_q,sh_q;
  logic [2:0] result_reg_q;
  logic [4:0] shader_length_q;
  wire shader_ready,shader_busy,shader_done,shader_fault;
  wire [31:0] shader_color;
  wire [4:0] retired;
  wire raster_clear_ready,raster_tri_ready,raster_tri_done,raster_busy,raster_fault;
  wire raster_host_ready;
  wire launch=shaded_tri_valid && shaded_tri_ready;
  wire shader_launch=state_q==IDLE && launch;
  wire tri_issue=state_q==DRAW_ISSUE && raster_tri_ready;
  assign clear_ready=rst_n && state_q==IDLE && shader_ready && raster_clear_ready && !raster_fault;
  assign shaded_tri_ready=rst_n && state_q==IDLE && shader_ready && raster_tri_ready && !clear_valid && !fault;
  assign initialized=raster_initialized;
  wire raster_initialized;
  assign busy=(state_q!=IDLE && state_q!=FAILED) || raster_busy;
  assign fault=state_q==FAILED || shader_fault || raster_fault;
  assign shader_retired=retired;
  assign host_read_ready=(state_q==IDLE && !shaded_tri_valid && !clear_valid) && raster_host_ready;
  a0_p151_unorm_microprogram shader(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid(reg_write_valid && state_q==IDLE && !launch && !clear_valid),
    .reg_write_index(reg_write_index),.reg_write_data(reg_write_data),
    .reg_read_index(result_reg_q),.reg_read_data(shader_color),
    .insn_write_valid(insn_write_valid && state_q==IDLE && !launch && !clear_valid),
    .insn_write_index(insn_write_index),.insn_write_data(insn_write_data),
    .start(shader_launch),.start_length(shader_length),
    .ready(shader_ready),.busy(shader_busy),.done(shader_done),
    .fault(shader_fault),.retired_count(retired)
  );
  a0_p145_dual_raster_depth_blend_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) raster(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid && clear_ready),.clear_ready(raster_clear_ready),
    .clear_done(clear_done),.clear_color(clear_color),.clear_depth(clear_depth),
    .tri_valid(tri_issue),.tri_ready(raster_tri_ready),.tri_done(raster_tri_done),
    .x0(ax),.y0(ay),.x1(bx),.y1(by),.x2(cx),.y2(cy),
    .tri_color(color_q),.tri_depth(depth_q),.depth_compare_op(depth_op_q),
    .depth_write(depth_write_q),.blend_enable(blend_q),
    .source_alpha(alpha_q),.scissor_enable(scissor_q),
    .scissor_x(sx_q),.scissor_y(sy_q),.scissor_w(sw_q),.scissor_h(sh_q),
    .initialized(raster_initialized),.busy(raster_busy),.fault(raster_fault),
    .pixel_writes(pixel_writes),
    .host_read_valid(host_read_valid && host_read_ready),
    .host_read_ready(raster_host_ready),.host_read_x(host_read_x),
    .host_read_y(host_read_y),.host_rsp_valid(host_rsp_valid),
    .host_rsp_error(host_rsp_error),.host_rsp_color(host_rsp_color),
    .host_rsp_depth(host_rsp_depth)
  );
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=IDLE;shaded_tri_done<=0;
      ax<=0;ay<=0;bx<=0;by<=0;cx<=0;cy<=0;
      depth_q<=0;color_q<=0;depth_op_q<=0;
      depth_write_q<=0;blend_q<=0;scissor_q<=0;
      alpha_q<=0;sx_q<=0;sy_q<=0;sw_q<=0;sh_q<=0;
      result_reg_q<=0;shader_length_q<=0;
    end else begin
      shaded_tri_done<=0;
      if(state_q==IDLE && launch)begin
        ax<=x0;ay<=y0;bx<=x1;by<=y1;cx<=x2;cy<=y2;
        depth_q<=tri_depth;depth_op_q<=depth_compare_op;
        depth_write_q<=depth_write;blend_q<=blend_enable;
        alpha_q<=source_alpha;scissor_q<=scissor_enable;
        sx_q<=scissor_x;sy_q<=scissor_y;sw_q<=scissor_w;sh_q<=scissor_h;
        result_reg_q<=color_result_reg;
        shader_length_q<=shader_length;
        state_q<=SHADE;
      end else if(state_q==SHADE)begin
        if(shader_fault)state_q<=FAILED;
        else if(shader_done)begin
          color_q<=shader_color[23:0];
          state_q<=DRAW_ISSUE;
        end
      end else if(state_q==DRAW_ISSUE)begin
        if(raster_fault)state_q<=FAILED;
        else if(raster_tri_ready)state_q<=DRAW_WAIT;
      end else if(state_q==DRAW_WAIT)begin
        if(raster_fault)state_q<=FAILED;
        else if(raster_tri_done)begin
          shaded_tri_done<=1;
          state_q<=IDLE;
        end
      end
    end
  end
endmodule
