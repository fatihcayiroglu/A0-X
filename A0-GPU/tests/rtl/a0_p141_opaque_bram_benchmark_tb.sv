`timescale 1ns/1ps
// P141: actual RTL A/B comparison of P140 against frozen original P140.
// Compare every RGB+depth word after each draw, and measure EXACT
// command-to-done clock cycles (not predicted pixels/sec or card FPS).
module a0_p141_opaque_bram_benchmark_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
);
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,clear_valid=0,tri_valid=0;
  reg [23:0] clear_color=24'h102030,clear_depth=24'hffffff;
  reg [23:0] tri_color=24'h2277dd,tri_depth=24'h000060;
  reg signed [15:0] x0=-16,y0=-16,x1=64,y1=-16,x2=-16,y2=64;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0,scissor_enable=0;
  reg [7:0] source_alpha=8'd255;
  reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
  reg host_read_valid=0;
  reg [15:0] host_read_x=0,host_read_y=0;

  wire [1:0] clear_ready,clear_done,tri_ready,tri_done,initialized,busy,wrote;
  wire [1:0] host_read_ready,host_rsp_valid,host_rsp_error;
  wire [23:0] color_new,color_old,depth_new,depth_old;
  integer cycle=0,draws=0,compared=0,fast_saving=0;
  integer new_writes=0,old_writes=0;

  a0_p140_raster_bram_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) optimized (
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid),.clear_ready(clear_ready[0]),
    .clear_color(clear_color),.clear_depth(clear_depth),.clear_done(clear_done[0]),
    .tri_valid(tri_valid),.tri_ready(tri_ready[0]),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(tri_done[0]),.initialized(initialized[0]),
    .busy(busy[0]),.pixel_wrote(wrote[0]),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready[0]),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid[0]),.host_rsp_error(host_rsp_error[0]),
    .host_rsp_color(color_new),.host_rsp_depth(depth_new)
  );
  a0_p140_raster_bram_trial_p141_reference #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) original (
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid),.clear_ready(clear_ready[1]),
    .clear_color(clear_color),.clear_depth(clear_depth),.clear_done(clear_done[1]),
    .tri_valid(tri_valid),.tri_ready(tri_ready[1]),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(tri_done[1]),.initialized(initialized[1]),
    .busy(busy[1]),.pixel_wrote(wrote[1]),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready[1]),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid[1]),.host_rsp_error(host_rsp_error[1]),
    .host_rsp_color(color_old),.host_rsp_depth(depth_old)
  );

  always @(posedge clk) begin
    cycle=cycle+1;
    #1;
    if(rst_n && wrote[0])new_writes=new_writes+1;
    if(rst_n && wrote[1])old_writes=old_writes+1;
  end

  task automatic frame_equal;
    begin
      for(integer y=0;y<FRAME_HEIGHT;y=y+1)
        for(integer x=0;x<FRAME_WIDTH;x=x+1) begin
          @(negedge clk);
          if(host_read_ready!==2'b11)
            $fatal(1,"P141 host read not ready after draw");
          host_read_x=16'(x);host_read_y=16'(y);host_read_valid=1;
          @(posedge clk); #2;
          if(host_rsp_valid!==2'b11 || host_rsp_error!==2'b00 ||
             color_new !== color_old || depth_new !== depth_old)
            $fatal(1,"P141 color/depth mismatch XY=%0d,%0d old=%h/%h new=%h/%h valid=%b err=%b",
              x,y,color_old,depth_old,color_new,depth_new,
              host_rsp_valid,host_rsp_error);
          compared=compared+1;
          @(negedge clk);host_read_valid=0;
        end
    end
  endtask

  task automatic clear_both;
    reg [1:0] seen;
    begin
      @(negedge clk);
      if(clear_ready!==2'b11) $fatal(1,"P141 clear not ready");
      clear_valid=1;
      @(negedge clk); clear_valid=0;
      seen=2'b00;
      for(integer t=0;t<FRAME_WIDTH*FRAME_HEIGHT*6+30 && seen!==2'b11;t=t+1)begin
        if(clear_done[0])seen[0]=1;
        if(clear_done[1])seen[1]=1;
        @(negedge clk);
      end
      if(seen!==2'b11 || initialized!==2'b11)
        $fatal(1,"P141 clear completion did not occur");
      frame_equal();
    end
  endtask

  task automatic draw_both(input integer mode);
    reg [1:0] seen;
    integer new_cycles,old_cycles,start_cycle,initial_new,initial_old;
    begin
      @(negedge clk);
      if(tri_ready!==2'b11) $fatal(1,"P141 triangle not ready mode=%0d",mode);
      initial_new=new_writes;initial_old=old_writes;
      tri_valid=1;
      @(negedge clk);tri_valid=0;
      start_cycle=cycle;
      seen=2'b00;new_cycles=-1;old_cycles=-1;
      for(integer t=0;t<FRAME_WIDTH*FRAME_HEIGHT*6+50 && seen!==2'b11;t=t+1)begin
        if(tri_done[0] && !seen[0]) begin
          seen[0]=1;new_cycles=cycle-start_cycle;
        end
        if(tri_done[1] && !seen[1]) begin
          seen[1]=1;old_cycles=cycle-start_cycle;
        end
        @(negedge clk);
      end
      if(seen!==2'b11) $fatal(1,"P141 timeout mode=%0d seen=%b",mode,seen);
      frame_equal();
      if(new_writes-initial_new!==old_writes-initial_old)
        $fatal(1,"P141 write count differs mode=%0d old=%0d new=%0d",mode,
            old_writes-initial_old,new_writes-initial_new);
      if(mode==0) begin
        if(new_writes-initial_new<FRAME_WIDTH*FRAME_HEIGHT/2 ||
           new_cycles>=old_cycles)
          $fatal(1,"P141 opaque path failed positive cycle saving: new=%0d old=%0d writes=%0d",
            new_cycles,old_cycles,new_writes-initial_new);
        fast_saving=old_cycles-new_cycles;
      end else if(mode==1) begin
        // Blending needs a previous color: cannot take opaque fast path.
        if(new_cycles!==old_cycles)
          $fatal(1,"P141 blending must preserve slow-path latency");
      end else if(mode==2) begin
        // Preserved depth uses prior stored depth, so a read remains required.
        if(new_cycles!==old_cycles)
          $fatal(1,"P141 depth_write disabled must preserve slow path");
      end else if(mode==3) begin
        // Completely scissor-rejected triangle: no RAM read/write needed.
        if(new_cycles>=old_cycles)
          $fatal(1,"P141 scissor reject fast advance must save cycles");
      end
      draws=draws+1;
      $display("P141_DRAW_METRIC_PASS shape=%0dx%0d mode=%0d optimized_cycles=%0d original_cycles=%0d writes=%0d",
         FRAME_WIDTH,FRAME_HEIGHT,mode,new_cycles,old_cycles,new_writes-initial_new);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    clear_both();
    depth_compare_op=2'd0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw_both(0);
    tri_color=24'hbc2578;tri_depth=24'h000008;
    blend_enable=1;source_alpha=8'd131;
    draw_both(1);
    blend_enable=0;depth_write=0;tri_color=24'h228844;
    draw_both(2);
    depth_write=1;scissor_enable=1;
    scissor_x=16'(FRAME_WIDTH);scissor_y=16'(FRAME_HEIGHT);
    scissor_w=1;scissor_h=1;
    draw_both(3);
    if(draws!=4 || compared<5*FRAME_WIDTH*FRAME_HEIGHT || fast_saving<2)
      $fatal(1,"P141 insufficient measurement draws=%0d pixels=%0d saved=%0d",
         draws,compared,fast_saving);
    $display("P141_OPAQUE_FASTPATH_BENCHMARK_PASS shape=%0dx%0d opaque_saved_cycles=%0d frames_compared=%0d",
       FRAME_WIDTH,FRAME_HEIGHT,fast_saving,compared);
    $finish;
  end
  initial begin #2000000;$fatal(1,"P141 watchdog");end
endmodule
