`timescale 1ns/1ps
module a0_p152_shader_triangle_diff_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,clear_valid=0,shaded_tri_valid=0;
  reg reg_write_valid=0,insn_write_valid=0,host_read_valid=0;
  reg [2:0] reg_write_index=0,color_result_reg=2;
  reg [31:0] reg_write_data=0;
  reg [3:0] insn_write_index=0;
  reg [23:0] insn_write_data=0;
  reg [4:0] shader_length=1;
  reg signed [15:0] x0=-2,y0=-2,x1=7,y1=-2,x2=-2,y2=7;
  reg [23:0] tri_depth=24'h12,clear_color=0,clear_depth=24'hffffff;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0,scissor_enable=0;
  reg [7:0] source_alpha=0;
  reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
  reg [15:0] host_read_x=0,host_read_y=0,ref_read_x=0,ref_read_y=0;
  wire clear_ready,clear_done,shaded_tri_ready,shaded_tri_done;
  wire initialized,busy,fault,host_read_ready,host_rsp_valid,host_rsp_error;
  wire [4:0] shader_retired;
  wire [1:0] pixel_writes;
  wire [23:0] host_rsp_color,host_rsp_depth;
  wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done,ref_read_valid,ref_pixel_wrote;
  wire ref_initialized,ref_busy;
  wire [23:0] ref_color,ref_depth;
  reg [23:0] expected_color=24'h18a0c8;
  integer pixels=0,draws=0,dual=0;
  a0_p152_shaded_triangle_prepass #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),.clear_ready(clear_ready),
    .clear_done(clear_done),.clear_color(clear_color),.clear_depth(clear_depth),
    .reg_write_valid(reg_write_valid),.reg_write_index(reg_write_index),
    .reg_write_data(reg_write_data),.insn_write_valid(insn_write_valid),
    .insn_write_index(insn_write_index),.insn_write_data(insn_write_data),
    .shaded_tri_valid(shaded_tri_valid),.shaded_tri_ready(shaded_tri_ready),
    .shaded_tri_done(shaded_tri_done),.shader_length(shader_length),
    .color_result_reg(color_result_reg),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_depth(tri_depth),.depth_compare_op(depth_compare_op),
    .depth_write(depth_write),.blend_enable(blend_enable),
    .source_alpha(source_alpha),.scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .initialized(initialized),.busy(busy),.fault(fault),
    .shader_retired(shader_retired),.pixel_writes(pixel_writes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );
  a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid),.clear_ready(ref_clear_ready),
    .clear_done(ref_clear_done),.clear_color(clear_color),.clear_depth(clear_depth),
    .tri_valid(shaded_tri_valid && shaded_tri_ready),.tri_ready(ref_tri_ready),
    .tri_done(ref_tri_done),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(expected_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .initialized(ref_initialized),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),.read_valid(ref_read_valid),
    .read_color(ref_color),.read_depth(ref_depth),.pixel_wrote(ref_pixel_wrote)
  );
  always @(posedge clk)if(rst_n && pixel_writes==2'b11)dual=dual+1;
  task automatic load_register(input [2:0] idx,input [31:0] data);
    begin
      @(negedge clk);reg_write_index=idx;reg_write_data=data;reg_write_valid=1;
      @(negedge clk);reg_write_valid=0;
    end
  endtask
  task automatic load_instruction(input [23:0] data);
    begin
      @(negedge clk);insn_write_index=0;insn_write_data=data;insn_write_valid=1;
      @(negedge clk);insn_write_valid=0;
    end
  endtask
  task automatic frame_compare;
    integer n;
    begin
      for(integer yy=0;yy<4;yy=yy+1)
        for(integer xx=0;xx<4;xx=xx+1)begin
          @(negedge clk);
          ref_read_x=16'(xx);ref_read_y=16'(yy);
          host_read_x=16'(xx);host_read_y=16'(yy);
          host_read_valid=1;
          n=0;
          while(!host_read_ready)begin
            @(negedge clk);n=n+1;
            if(n>100)$fatal(1,"P152 readback stalled");
          end
          @(negedge clk);host_read_valid=0;
          n=0;
          while(!host_rsp_valid)begin
            @(negedge clk);n=n+1;
            if(n>100)$fatal(1,"P152 host read response missing");
          end
          if(!ref_read_valid || host_rsp_error ||
             host_rsp_color!==ref_color || host_rsp_depth!==ref_depth)
            $fatal(1,"P152 P102 mismatch (%0d,%0d) ref=%h/%h gpu=%h/%h",
               xx,yy,ref_color,ref_depth,host_rsp_color,host_rsp_depth);
          pixels=pixels+1;
        end
    end
  endtask
  integer n;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    @(negedge clk);clear_valid=1;
    @(negedge clk);clear_valid=0;
    n=0;
    while(!clear_done || !ref_initialized)begin
      @(negedge clk);n=n+1;
      if(n>180)$fatal(1,"P152 clear timed out");
    end
    load_register(1,32'h0018a0c8);
    // MOV_B to register2 from register1: alpha=0, mask=F,
    // opcode=1, dst=2, srcA=0, srcB=1.
    load_instruction({8'd0,4'hf,3'd1,3'd2,3'd0,3'd1});
    @(negedge clk);shaded_tri_valid=1;
    if(!shaded_tri_ready || !ref_tri_ready)$fatal(1,"P152 not ready");
    @(negedge clk);shaded_tri_valid=0;
    n=0;
    while(!shaded_tri_done || !ref_tri_done)begin
      @(negedge clk);n=n+1;
      if(n>360)$fatal(1,"P152 shaded triangle never completed");
    end
    if(fault || shader_retired!=1)$fatal(1,"P152 shader retirement/fault");
    draws=draws+1;
    frame_compare();
    if(pixels!=16 || draws!=1 || dual<1)
      $fatal(1,"P152 insufficient shader/raster pixel coverage");
    $display("P152_SHADED_TRIANGLE_P102_PASS checked_pixels=%0d shaded_draws=%0d dual_write_cycles=%0d shader_retired=%0d",
       pixels,draws,dual,shader_retired);
    $finish;
  end
  initial begin #1000000;$fatal(1,"P152 watchdog");end
endmodule
