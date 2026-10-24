`timescale 1ns/1ps
// P145 differential: original P102's async framebuffer vs a real
// P139/P138 synchronous FPGA-BRAM backed read/depth/blend/write renderer.
// Compare EVERY pixel color and depth after clear and each triangle, not
// cycle latency (new BRAM path legitimately stalls raster).
module a0_p152_shader_triangle_p102_diff_tb #(
  parameter integer FRAME_WIDTH=4, FRAME_HEIGHT=4
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,clear_valid=0,tri_valid=0;
  reg [23:0] clear_color=0,clear_depth=0,tri_color=0,tri_depth=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0,scissor_enable=0;
  reg [7:0] source_alpha=0;
  reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
  reg host_read_valid=0;reg [15:0] host_read_x=0,host_read_y=0;
  reg [15:0] ref_read_x=0,ref_read_y=0;
  wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done,ref_init,ref_busy;
  wire ref_read_valid,ref_wrote;
  wire [23:0] ref_color,ref_depth;
  wire dut_clear_ready,dut_clear_done,dut_tri_ready,dut_tri_done,dut_init,dut_busy;
  wire [1:0] dut_write_lanes;
  wire dut_fault,host_read_ready,host_rsp_valid,host_rsp_error;
  wire [23:0] host_color,host_depth;
  reg shader_reg_write_valid=0,shader_insn_write_valid=0;
  reg [2:0] shader_reg_write_index=0,shader_debug_index=0;
  reg [31:0] shader_reg_write_data=0;
  reg [3:0] shader_insn_write_index=0;
  reg [23:0] shader_insn_write_data=0;
  reg [4:0] shader_program_length=1;
  wire shader_config_ready,shader_done;
  wire [4:0] shader_retired_count;
  wire [31:0] shader_debug_data;
  wire [23:0] last_shaded_rgb;
  integer shader_completed=0,shader_retire_total=0;
  wire ref_fire=candidate.raster_issue && candidate.core_tri_ready;
  integer clears=0,draws=0,checked_pixels=0,ref_written=0,dut_written=0;
  integer completed_ref_writes=0,completed_bram_writes=0;
  integer live_host_accepts=0,live_host_stalls=0;
  integer dual_write_cycles=0;

  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) reference (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(ref_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(ref_clear_done),
    .tri_valid(ref_fire),.tri_ready(ref_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(ref_tri_done),.initialized(ref_init),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),
    .read_valid(ref_read_valid),.read_color(ref_color),
    .read_depth(ref_depth),.pixel_wrote(ref_wrote)
  );
  a0_p152_shaded_triangle_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) candidate (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(dut_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(dut_clear_done),
    .tri_valid(tri_valid),.tri_ready(dut_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .shader_program_length(shader_program_length),
    .shader_reg_write_valid(shader_reg_write_valid),
    .shader_reg_write_index(shader_reg_write_index),
    .shader_reg_write_data(shader_reg_write_data),
    .shader_insn_write_valid(shader_insn_write_valid),
    .shader_insn_write_index(shader_insn_write_index),
    .shader_insn_write_data(shader_insn_write_data),
    .shader_debug_index(shader_debug_index),
    .shader_debug_data(shader_debug_data),
    .shader_config_ready(shader_config_ready),
    .shader_done(shader_done),
    .shader_retired_count(shader_retired_count),
    .last_shaded_rgb(last_shaded_rgb),
    .tri_done(dut_tri_done),.initialized(dut_init),.busy(dut_busy),
    .fault(dut_fault),.pixel_writes(dut_write_lanes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_color),.host_rsp_depth(host_depth)
  );
  always @(posedge clk) begin
    if(rst_n && host_read_valid && dut_busy) begin
      if(host_read_ready)live_host_accepts=live_host_accepts+1;
      else live_host_stalls=live_host_stalls+1;
    end
    #1;
    if(rst_n && shader_done)begin
      shader_completed=shader_completed+1;
      shader_retire_total=shader_retire_total+int'(shader_retired_count);
    end
    if(rst_n && dut_busy && host_rsp_valid && host_rsp_error)
      $fatal(1,"P145 in-flight host read returned error at valid XY");
    if(rst_n && ref_wrote)ref_written=ref_written+1;
    if(rst_n) begin
      dut_written=dut_written+int'(dut_write_lanes[0])+int'(dut_write_lanes[1]);
      if(dut_write_lanes==2'b11)dual_write_cycles=dual_write_cycles+1;
      if(dut_fault) $fatal(1,"P145 experimental raster fault latched");
    end
  end

  function automatic [31:0] scalar_shader(
    input reg [31:0] a,b,input reg [2:0] op,
    input reg [3:0] mask,input reg [7:0] alpha
  );
    integer lane,u,v,z,n;
    reg [31:0] result;
    begin
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        u=(a>>(lane*8))&255;
        v=(b>>(lane*8))&255;
        z=u;
        if(mask[lane])begin
          case(op)
            0:z=u;
            1:z=v;
            2:begin n=u+v;z=(n>255)?255:n;end
            3:z=(u<v)?0:u-v;
            4:z=(u*v+127)/255;
            5:z=(u<v)?u:v;
            6:z=(u>v)?u:v;
            7:z=(u*(255-int'(alpha))+v*int'(alpha)+127)/255;
          endcase
        end
        result[8*lane+:8]=8'(z);
      end
      scalar_shader=result;
    end
  endfunction
  task automatic load_reg(input reg [2:0] idx,input reg [31:0] val);
    begin
      @(negedge clk);
      if(!shader_config_ready) $fatal(1,"P152 shader not idle for register loading");
      shader_reg_write_index=idx;shader_reg_write_data=val;
      shader_reg_write_valid=1;
      @(negedge clk);shader_reg_write_valid=0;
    end
  endtask
  task automatic load_insn(input reg [3:0] idx,input reg [23:0] val);
    begin
      @(negedge clk);
      if(!shader_config_ready) $fatal(1,"P152 shader not idle for instruction loading");
      shader_insn_write_index=idx;shader_insn_write_data=val;
      shader_insn_write_valid=1;
      @(negedge clk);shader_insn_write_valid=0;
    end
  endtask
  task automatic configure_shader(
    input reg [31:0] a,b,
    input reg [2:0] op0,op1,
    input reg [7:0] alpha0,alpha1,
    input reg [3:0] mask0,mask1,
    input integer count
  );
    reg [31:0] middle,final_vec;
    begin
      middle=scalar_shader(a,b,op0,mask0,alpha0);
      final_vec=(count==2)?
        scalar_shader(middle,b,op1,mask1,alpha1):middle;
      tri_color=final_vec[23:0];
      load_reg(3'd0,a);
      load_reg(3'd1,b);
      load_insn(4'd0,{alpha0,mask0,op0,3'd2,3'd0,3'd1});
      if(count==2)
        load_insn(4'd1,{alpha1,mask1,op1,3'd2,3'd2,3'd1});
      shader_program_length=5'(count);
    end
  endtask

  task automatic read_xy(input integer x,y);
    integer retry;
    begin
      @(negedge clk);
      host_read_x=16'(x);host_read_y=16'(y);host_read_valid=1;
      ref_read_x=16'(x);ref_read_y=16'(y);
      retry=0;
      while(!host_read_ready) begin
        @(negedge clk);
        retry=retry+1;
        if(retry>2*FRAME_WIDTH*FRAME_HEIGHT+20)
          $fatal(1,"P145 host read timeout at x=%0d y=%0d",x,y);
      end
      @(posedge clk);
      @(negedge clk);
      host_read_valid=0;
      if(!host_rsp_valid)
        $fatal(1,"P145 missing accepted read response at x=%0d y=%0d",x,y);
      if(x>=0 && x<FRAME_WIDTH && y>=0 && y<FRAME_HEIGHT) begin
        if(!ref_read_valid || host_rsp_error ||
            host_color !== ref_color || host_depth !== ref_depth)
          $fatal(1,"P145 framebuffer DIFF (%0d,%0d) original=%h/%h BRAM=%h/%h valid=%b err=%b",
            x,y,ref_color,ref_depth,host_color,host_depth,
            host_rsp_valid,host_rsp_error);
        checked_pixels=checked_pixels+1;
      end else if(ref_read_valid || !host_rsp_error ||
                  host_color !== 0 || host_depth !== 0)
        $fatal(1,"P145 invalid host XY not properly rejected (%0d,%0d)",x,y);
    end
  endtask
  task automatic compare_frame;
    begin
      if(!ref_init || !dut_init) $fatal(1,"P145 frame not initialized");
      for(integer y=0;y<FRAME_HEIGHT;y=y+1)
        for(integer x=0;x<FRAME_WIDTH;x=x+1)
          read_xy(x,y);
      read_xy(FRAME_WIDTH,0);
      read_xy(0,FRAME_HEIGHT);
    end
  endtask
  task automatic start_clear(input reg [23:0] cc,dd);
    reg done_a,done_b;
    begin
      @(negedge clk);
      if(!ref_clear_ready || !dut_clear_ready)
        $fatal(1,"P145 reference/candidate not ready to clear");
      clear_color=cc;clear_depth=dd;clear_valid=1;
      @(negedge clk);clear_valid=0;
      done_a=ref_clear_done;done_b=dut_clear_done;
      for(integer j=0;j<FRAME_WIDTH*FRAME_HEIGHT*5+40 && !(done_a&&done_b);j=j+1) begin
        @(negedge clk);
        if(ref_clear_done)done_a=1;
        if(dut_clear_done)done_b=1;
      end
      if(!(done_a&&done_b))
        $fatal(1,"P145 clear not completed ref=%b dut=%b",done_a,done_b);
      clears=clears+1;
      compare_frame();
    end
  endtask
  task automatic draw(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    reg done_a,done_b;
    integer started_ref,started_bram;
    begin
      @(negedge clk);
      if(!ref_tri_ready || !dut_tri_ready)
        $fatal(1,"P145 not ready for triangle");
      started_ref=ref_written;started_bram=dut_written;
      x0=xa;y0=ya;x1=xb;y1=yb;x2=xc;y2=yc;
      tri_valid=1;
      @(negedge clk);
      tri_valid=0;
      // P152 launches P102 ONLY AFTER real shader completion.
      // Keep reference inputs unchanged until the shared raster launch.
      done_a=ref_tri_done;done_b=dut_tri_done;
      // Concurrent debug access to the SAME coordinate during active
      // triangle processing exercises lane-1 arbitration/backpressure.
      host_read_valid=0;
      for(integer j=0;j<FRAME_WIDTH*FRAME_HEIGHT*8+100 && !(done_a&&done_b);j=j+1) begin
        @(negedge clk);
        host_read_x=0;host_read_y=0;
        host_read_valid=(j<14);
        if(ref_tri_done)done_a=1;
        if(dut_tri_done)done_b=1;
      end
      host_read_valid=0;
      if(!(done_a&&done_b))
        $fatal(1,"P145 triangle not completed ref=%b dut=%b",done_a,done_b);
      draws=draws+1;
      if(last_shaded_rgb!==tri_color || shader_retired_count!=shader_program_length)
        $fatal(1,"P152 shader output incorrect shader=%h scalar=%h retire=%0d",
               last_shaded_rgb,tri_color,shader_retired_count);
      compare_frame();
      if(ref_written-started_ref != dut_written-started_bram)
        $fatal(1,"P145 completed triangle writes differ: ref=%0d BRAM=%0d draw=%0d",
          ref_written-started_ref,dut_written-started_bram,draws);
      completed_ref_writes=completed_ref_writes+(ref_written-started_ref);
      completed_bram_writes=completed_bram_writes+(dut_written-started_bram);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    start_clear(24'h112233,24'hffffff);
    configure_shader(32'h3090e040,32'h1020c0df,3'd2,3'd0,8'd0,8'd0,4'hf,4'h0,1);
    tri_depth=24'h000040;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    configure_shader(32'hff00ac18,32'h102060f0,3'd7,3'd5,8'd128,8'd0,4'hf,4'hf,2);
    tri_depth=24'h000020;
    depth_compare_op=1;depth_write=1;blend_enable=1;source_alpha=8'd128;
    scissor_enable=1;scissor_x=1;scissor_y=0;
    scissor_w=16'(FRAME_WIDTH);scissor_h=16'(FRAME_HEIGHT);
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    configure_shader(32'hfd101020,32'h80c080c0,3'd4,3'd1,8'd0,8'd0,4'hf,4'h0,1);
    tri_depth=24'h000010;
    depth_compare_op=2;depth_write=0;blend_enable=1;source_alpha=8'd191;
    scissor_enable=0;
    draw(-16'sd5,-16'sd5,-16'sd5,16'sd20,16'sd20,-16'sd5);
    configure_shader(32'h78441122,32'h133767b1,3'd3,3'd0,8'd0,8'd0,4'hf,4'h0,1);
    tri_depth=24'h000080;
    depth_compare_op=0;depth_write=1;blend_enable=0;
    draw(0,0,0,0,0,0);
    // Abort an active triangle using shared reset; no old memory survives.
    @(negedge clk);
    if(!ref_tri_ready || !dut_tri_ready) $fatal(1,"P145 pre-reset not ready");
    x0=-5;y0=-5;x1=20;y1=-5;x2=-5;y2=20;tri_valid=1;
    @(negedge clk);tri_valid=0;
    repeat(4) @(negedge clk);
    rst_n=0;
    repeat(4) @(negedge clk);
    if(ref_init || dut_init || ref_tri_done || dut_tri_done)
      $fatal(1,"P145 state not flushed by reset");
    rst_n=1;
    start_clear(24'h010203,24'hffffff);
    configure_shader(32'h847362ff,32'h0000ff01,3'd6,3'd0,8'd0,8'd0,4'hf,4'h0,1);
    tri_depth=24'h000008;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    if(clears!=2 || draws!=5 || shader_completed<5 ||
       shader_retire_total<6 || checked_pixels<6*FRAME_WIDTH*FRAME_HEIGHT ||
       completed_ref_writes<5 || completed_ref_writes!=completed_bram_writes ||
       dual_write_cycles<1 || live_host_stalls<1)
      $fatal(1,"P145 missing coverage clears=%0d draws=%0d checked=%0d writes ref=%0d dut=%0d",
        clears,draws,checked_pixels,completed_ref_writes,completed_bram_writes);
    $display("P152_SHADER_TO_BRAM_P102_FRAME_PASS size=%0dx%0d clears=%0d draws=%0d checked=%0d ref_writes=%0d bram_writes=%0d dual_write_cycles=%0d host_stall=%0d shader_exec=%0d retired=%0d",
      FRAME_WIDTH,FRAME_HEIGHT,clears,draws,checked_pixels,completed_ref_writes,completed_bram_writes,dual_write_cycles,live_host_stalls,shader_completed,shader_retire_total);
    $finish;
  end
  initial begin #6000000; $fatal(1,"P145 RTL differential watchdog"); end
endmodule
