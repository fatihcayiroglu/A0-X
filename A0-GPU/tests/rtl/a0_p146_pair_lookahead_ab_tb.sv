`timescale 1ns/1ps
// P146 differential: original P102's async framebuffer vs a real
// P139/P138 synchronous FPGA-BRAM backed read/depth/blend/write renderer.
// Compare EVERY pixel color and depth after clear and each triangle, not
// cycle latency (new BRAM path legitimately stalls raster).
module a0_p146_pair_lookahead_ab_tb #(
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
  integer clears=0,draws=0,checked_pixels=0,ref_written=0,dut_written=0;
  integer completed_ref_writes=0,completed_bram_writes=0;
  integer live_host_accepts=0,live_host_stalls=0;
  integer dual_write_cycles=0;
  wire old_clear_ready,old_clear_done,old_tri_ready,old_tri_done,old_init,old_busy,old_fault;
  wire [1:0] old_write_lanes;
  wire old_host_read_ready,old_host_rsp_valid,old_host_rsp_error;
  wire [23:0] old_host_color,old_host_depth;
  integer old_written=0,cycle_counter=0,completed_old_writes=0;
  integer total_old_cycles=0,total_new_cycles=0,strictly_faster_draws=0;

  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) reference (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(ref_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(ref_clear_done),
    .tri_valid(tri_valid),.tri_ready(ref_tri_ready),
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
  a0_p145_dual_raster_depth_blend_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) candidate (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(dut_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(dut_clear_done),
    .tri_valid(tri_valid),.tri_ready(dut_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(dut_tri_done),.initialized(dut_init),.busy(dut_busy),
    .fault(dut_fault),.pixel_writes(dut_write_lanes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_color),.host_rsp_depth(host_depth)
  );
  a0_p145_pre_p146_reference #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) frozen_old(
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(old_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(old_clear_done),
    .tri_valid(tri_valid),.tri_ready(old_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(old_tri_done),.initialized(old_init),.busy(old_busy),
    .fault(old_fault),.pixel_writes(old_write_lanes),
    .host_read_valid(host_read_valid),.host_read_ready(old_host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(old_host_rsp_valid),.host_rsp_error(old_host_rsp_error),
    .host_rsp_color(old_host_color),.host_rsp_depth(old_host_depth)
  );
  always @(posedge clk) begin
    cycle_counter=cycle_counter+1;
    if(rst_n && host_read_valid && dut_busy) begin
      if(host_read_ready)live_host_accepts=live_host_accepts+1;
      else live_host_stalls=live_host_stalls+1;
    end
    #1;
    if(rst_n && dut_busy && host_rsp_valid && host_rsp_error)
      $fatal(1,"P146 in-flight host read returned error at valid XY");
    if(rst_n && ref_wrote)ref_written=ref_written+1;
    if(rst_n) begin
      old_written=old_written+int'(old_write_lanes[0])+int'(old_write_lanes[1]);
      if(old_fault) $fatal(1,"P146 frozen original fault latched");
    end
    if(rst_n) begin
      dut_written=dut_written+int'(dut_write_lanes[0])+int'(dut_write_lanes[1]);
      if(dut_write_lanes==2'b11)dual_write_cycles=dual_write_cycles+1;
      if(dut_fault) $fatal(1,"P146 experimental raster fault latched");
    end
  end

  task automatic read_xy(input integer x,y);
    integer retry;
    begin
      @(negedge clk);
      host_read_x=16'(x);host_read_y=16'(y);host_read_valid=1;
      ref_read_x=16'(x);ref_read_y=16'(y);
      retry=0;
      while(!host_read_ready || !old_host_read_ready) begin
        @(negedge clk);
        retry=retry+1;
        if(retry>2*FRAME_WIDTH*FRAME_HEIGHT+20)
          $fatal(1,"P146 host read timeout at x=%0d y=%0d",x,y);
      end
      @(posedge clk);
      @(negedge clk);
      host_read_valid=0;
      if(!host_rsp_valid || !old_host_rsp_valid)
        $fatal(1,"P146 missing accepted read response at x=%0d y=%0d",x,y);
      if(x>=0 && x<FRAME_WIDTH && y>=0 && y<FRAME_HEIGHT) begin
        if(!ref_read_valid || host_rsp_error || old_host_rsp_error ||
            host_color !== ref_color || host_depth !== ref_depth ||
            old_host_color !== ref_color || old_host_depth !== ref_depth)
          $fatal(1,"P146 framebuffer DIFF (%0d,%0d) original=%h/%h BRAM=%h/%h valid=%b err=%b",
            x,y,ref_color,ref_depth,host_color,host_depth,
            host_rsp_valid,host_rsp_error);
        checked_pixels=checked_pixels+1;
      end else if(ref_read_valid || !host_rsp_error || !old_host_rsp_error ||
                  host_color !== 0 || host_depth !== 0 ||
                  old_host_color !== 0 || old_host_depth !== 0)
        $fatal(1,"P146 invalid host XY not properly rejected (%0d,%0d)",x,y);
    end
  endtask
  task automatic compare_frame;
    begin
      if(!ref_init || !dut_init || !old_init) $fatal(1,"P146 A/B frame not initialized");
      for(integer y=0;y<FRAME_HEIGHT;y=y+1)
        for(integer x=0;x<FRAME_WIDTH;x=x+1)
          read_xy(x,y);
      read_xy(FRAME_WIDTH,0);
      read_xy(0,FRAME_HEIGHT);
    end
  endtask
  task automatic start_clear(input reg [23:0] cc,dd);
    reg done_a,done_b,done_old;
    begin
      @(negedge clk);
      if(!ref_clear_ready || !dut_clear_ready || !old_clear_ready)
        $fatal(1,"P146 reference/candidate not ready to clear");
      clear_color=cc;clear_depth=dd;clear_valid=1;
      @(negedge clk);clear_valid=0;
      done_a=ref_clear_done;done_b=dut_clear_done;done_old=old_clear_done;
      for(integer j=0;j<FRAME_WIDTH*FRAME_HEIGHT*5+40 && !(done_a&&done_b&&done_old);j=j+1) begin
        @(negedge clk);
        if(ref_clear_done)done_a=1;
        if(dut_clear_done)done_b=1;
        if(old_clear_done)done_old=1;
      end
      if(!(done_a&&done_b&&done_old))
        $fatal(1,"P146 clear not completed ref=%b dut=%b",done_a,done_b);
      clears=clears+1;
      compare_frame();
    end
  endtask
  task automatic draw(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    reg done_a,done_b,done_old;
    integer started_ref,started_bram,started_old;
    integer old_finished,new_finished,launch_cycle;
    begin
      @(negedge clk);
      if(!ref_tri_ready || !dut_tri_ready || !old_tri_ready)
        $fatal(1,"P146 not ready for triangle");
      started_ref=ref_written;started_bram=dut_written;started_old=old_written;
      x0=xa;y0=ya;x1=xb;y1=yb;x2=xc;y2=yc;
      tri_valid=1;
      @(negedge clk);
      tri_valid=0;
      // Both engines must keep the launch-time triangle state.
      x0=16'sh7fff;y0=16'sh8000;x1=-16'sd5;y1=16'sd9;
      tri_color=24'hff00ff;tri_depth=24'h000001;
      launch_cycle=cycle_counter;old_finished=-1;new_finished=-1;
      done_a=ref_tri_done;done_b=dut_tri_done;done_old=old_tri_done;
      // A zero-area triangle may assert tri_done immediately at launch.
      // Such a completed no-pixel draw legitimately has zero elapsed clocks.
      if(done_b)new_finished=0;
      if(done_old)old_finished=0;
      // Concurrent debug access to the SAME coordinate during active
      // triangle processing exercises lane-1 arbitration/backpressure.
      host_read_valid=0;
      for(integer j=0;j<FRAME_WIDTH*FRAME_HEIGHT*8+100 && !(done_a&&done_b&&done_old);j=j+1) begin
        @(negedge clk);
        host_read_x=0;host_read_y=0;
        host_read_valid=(j<14);
        if(ref_tri_done)done_a=1;
        if(dut_tri_done && !done_b) begin
          done_b=1;new_finished=cycle_counter-launch_cycle;
        end
        if(old_tri_done && !done_old) begin
          done_old=1;old_finished=cycle_counter-launch_cycle;
        end
      end
      host_read_valid=0;
      if(!(done_a&&done_b&&done_old))
        $fatal(1,"P146 triangle not completed ref=%b dut=%b",done_a,done_b);
      draws=draws+1;
      compare_frame();
      if(ref_written-started_ref != old_written-started_old)
        $fatal(1,"P146 preoptimized P146 write mismatch vs P102");
      if(ref_written-started_ref != dut_written-started_bram)
        $fatal(1,"P146 completed triangle writes differ: ref=%0d BRAM=%0d draw=%0d",
          ref_written-started_ref,dut_written-started_bram,draws);
      if(new_finished<0 || old_finished<0 || new_finished>old_finished)
        $fatal(1,"P146 lookahead must not increase draw cycles: original=%0d new=%0d",old_finished,new_finished);
      total_new_cycles=total_new_cycles+new_finished;
      total_old_cycles=total_old_cycles+old_finished;
      if(new_finished<old_finished)strictly_faster_draws=strictly_faster_draws+1;
      completed_old_writes=completed_old_writes+(old_written-started_old);
      $display("P146_DRAW_CYCLE_PASS shape=%0dx%0d old_cycles=%0d new_cycles=%0d writes=%0d",
        FRAME_WIDTH,FRAME_HEIGHT,old_finished,new_finished,dut_written-started_bram);
      completed_ref_writes=completed_ref_writes+(ref_written-started_ref);
      completed_bram_writes=completed_bram_writes+(dut_written-started_bram);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    start_clear(24'h112233,24'hffffff);
    tri_color=24'h3090e0;tri_depth=24'h000040;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    tri_color=24'h00ff18;tri_depth=24'h000020;
    depth_compare_op=1;depth_write=1;blend_enable=1;source_alpha=8'd128;
    scissor_enable=1;scissor_x=1;scissor_y=0;
    scissor_w=16'(FRAME_WIDTH);scissor_h=16'(FRAME_HEIGHT);
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    tri_color=24'hff1020;tri_depth=24'h000010;
    depth_compare_op=2;depth_write=0;blend_enable=1;source_alpha=8'd191;
    scissor_enable=0;
    draw(-16'sd5,-16'sd5,-16'sd5,16'sd20,16'sd20,-16'sd5);
    tri_color=24'h784411;tri_depth=24'h000080;
    depth_compare_op=0;depth_write=1;blend_enable=0;
    draw(0,0,0,0,0,0);
    // Abort an active triangle using shared reset; no old memory survives.
    @(negedge clk);
    if(!ref_tri_ready || !dut_tri_ready) $fatal(1,"P146 pre-reset not ready");
    x0=-5;y0=-5;x1=20;y1=-5;x2=-5;y2=20;tri_valid=1;
    @(negedge clk);tri_valid=0;
    repeat(4) @(negedge clk);
    rst_n=0;
    repeat(4) @(negedge clk);
    if(ref_init || dut_init || old_init || ref_tri_done || dut_tri_done || old_tri_done)
      $fatal(1,"P146 state not flushed by reset");
    rst_n=1;
    start_clear(24'h010203,24'hffffff);
    tri_color=24'h847362;tri_depth=24'h000008;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    if(clears!=2 || draws!=5 || checked_pixels<6*FRAME_WIDTH*FRAME_HEIGHT ||
       completed_ref_writes<5 || completed_ref_writes!=completed_bram_writes ||
       completed_old_writes!=completed_ref_writes || strictly_faster_draws<2 ||
       total_new_cycles>=total_old_cycles ||
       dual_write_cycles<1 || live_host_stalls<1)
      $fatal(1,"P146 missing coverage clears=%0d draws=%0d checked=%0d writes ref=%0d dut=%0d",
        clears,draws,checked_pixels,completed_ref_writes,completed_bram_writes);
    $display("P146_PAIR_LOOKAHEAD_AB_PASS size=%0dx%0d clears=%0d draws=%0d checked=%0d ref_writes=%0d bram_writes=%0d dual_write_cycles=%0d host_stall=%0d old_draw_cycles=%0d new_draw_cycles=%0d faster_draws=%0d",
      FRAME_WIDTH,FRAME_HEIGHT,clears,draws,checked_pixels,completed_ref_writes,completed_bram_writes,dual_write_cycles,live_host_stalls,total_old_cycles,total_new_cycles,strictly_faster_draws);
    $finish;
  end
  initial begin #6000000; $fatal(1,"P146 RTL differential watchdog"); end
endmodule
