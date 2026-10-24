`timescale 1ns/1ps
// P137: compare optimized P102 framebuffer address stepper to frozen old
// multiplication-address P102. Both instantiate the same actual P136 raster.
// This checks all externally observable responses cycle-by-cycle and every
// framebuffer color/depth pixel after each operation.
module a0_p137_linear_framebuffer_diff_tb #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4
);
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0,clear_valid=0,tri_valid=0;
  reg [23:0] clear_color=0,clear_depth=0,tri_color=0,tri_depth=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0,scissor_enable=0;
  reg [7:0] source_alpha=0;
  reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
  reg [15:0] read_x=0,read_y=0;
  wire a_clear_ready,a_clear_done,a_tri_ready,a_tri_done,a_init,a_busy,a_valid,a_wrote;
  wire b_clear_ready,b_clear_done,b_tri_ready,b_tri_done,b_init,b_busy,b_valid,b_wrote;
  wire [23:0] a_color,a_depth,b_color,b_depth;
  integer checks=0,draws=0,clears=0,pixel_writes=0,reads=0;

  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(a_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(a_clear_done),
    .tri_valid(tri_valid),.tri_ready(a_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(a_tri_done),.initialized(a_init),.busy(a_busy),
    .read_x(read_x),.read_y(read_y),
    .read_valid(a_valid),.read_color(a_color),
    .read_depth(a_depth),.pixel_wrote(a_wrote)
  );
  a0_triangle_scissor_depth_blend_p102_p137_reference #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) oracle (
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(b_clear_ready),.clear_color(clear_color),
    .clear_depth(clear_depth),.clear_done(b_clear_done),
    .tri_valid(tri_valid),.tri_ready(b_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(tri_color),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),
    .scissor_x(scissor_x),.scissor_y(scissor_y),
    .scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(b_tri_done),.initialized(b_init),.busy(b_busy),
    .read_x(read_x),.read_y(read_y),
    .read_valid(b_valid),.read_color(b_color),
    .read_depth(b_depth),.pixel_wrote(b_wrote)
  );

  // Probe a different coordinate after every clock, including in-flight
  // clears and draws; compare exact read/status and pixel-written pulses.
  always @(posedge clk) begin
    #1;
    read_x=(checks%FRAME_WIDTH);
    read_y=((checks/FRAME_WIDTH)%FRAME_HEIGHT);
    #1;
    if ({a_clear_ready,a_clear_done,a_tri_ready,a_tri_done,a_init,a_busy,
          a_valid,a_wrote,a_color,a_depth} !==
        {b_clear_ready,b_clear_done,b_tri_ready,b_tri_done,b_init,b_busy,
          b_valid,b_wrote,b_color,b_depth})
      $fatal(1,"P137 cycle mismatch %0d frame=%0dx%0d read=(%0d,%0d) status a=%b%b%b%b%b%b vs b=%b%b%b%b%b%b color a=%h b=%h depth a=%h b=%h",
        checks,FRAME_WIDTH,FRAME_HEIGHT,read_x,read_y,
        a_clear_ready,a_clear_done,a_tri_ready,a_tri_done,a_init,a_busy,
        b_clear_ready,b_clear_done,b_tri_ready,b_tri_done,b_init,b_busy,
        a_color,b_color,a_depth,b_depth);
    if(rst_n && a_wrote) pixel_writes=pixel_writes+1;
    if(a_valid) reads=reads+1;
    checks=checks+1;
  end

  task automatic assert_frame;
    begin
      for(integer y=0;y<FRAME_HEIGHT;y=y+1) begin
        for(integer x=0;x<FRAME_WIDTH;x=x+1) begin
          @(negedge clk);
          read_x=16'(x);read_y=16'(y);
          #1;
          if(!a_valid || !b_valid || a_color !== b_color || a_depth !== b_depth)
            $fatal(1,"P137 frame mismatch at (%0d,%0d) candidate=%h/%h old=%h/%h",
              x,y,a_color,a_depth,b_color,b_depth);
        end
      end
      @(negedge clk);
      read_x=16'(FRAME_WIDTH);read_y=0;
      #1;
      if(a_valid || b_valid || a_color !== 0 || b_color !== 0)
        $fatal(1,"P137 x-out-of-range read invalid contract");
      @(negedge clk);
      read_x=0;read_y=16'(FRAME_HEIGHT);
      #1;
      if(a_valid || b_valid || a_depth !== 0 || b_depth !== 0)
        $fatal(1,"P137 y-out-of-range read invalid contract");
    end
  endtask

  task automatic do_clear(input reg [23:0] cc,dd);
    reg seen;
    begin
      @(negedge clk);
      if(!a_clear_ready || !b_clear_ready)
        $fatal(1,"P137 clear not accepted");
      clear_color=cc;clear_depth=dd;clear_valid=1;
      @(negedge clk);
      clear_valid=0;
      seen=a_clear_done;
      for(integer k=0;k<FRAME_WIDTH*FRAME_HEIGHT+8 && !seen;k=k+1) begin
        @(negedge clk);
        if(a_clear_done) seen=1;
      end
      if(!seen) $fatal(1,"P137 clear timeout");
      clears=clears+1;
      assert_frame();
    end
  endtask

  task automatic do_tri(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    reg seen;
    begin
      @(negedge clk);
      if(!a_tri_ready || !b_tri_ready)
        $fatal(1,"P137 triangle not ready");
      x0=xa;y0=ya;x1=xb;y1=yb;x2=xc;y2=yc;
      tri_valid=1;
      @(negedge clk);
      tri_valid=0;
      // In-flight host source changes must not affect latched triangle.
      x0=16'sh7fff;y0=16'sh8000;x1=-16'sd1;y1=16'sd4;
      seen=a_tri_done;
      for(integer k=0;k<FRAME_WIDTH*FRAME_HEIGHT+8 && !seen;k=k+1) begin
        @(negedge clk);
        if(a_tri_done) seen=1;
      end
      if(!seen) $fatal(1,"P137 triangle timeout");
      draws=draws+1;
      assert_frame();
    end
  endtask

  initial begin
    repeat(4) @(negedge clk);
    rst_n=1;
    do_clear(24'h123456,24'hffffff);
    tri_color=24'h0077ff;tri_depth=24'h000040;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    do_tri(-16'sd6,-16'sd6,16'sd18,-16'sd6,-16'sd6,16'sd18);
    tri_color=24'hff2f15;tri_depth=24'h000030;
    depth_compare_op=1;depth_write=1;blend_enable=1;source_alpha=8'd127;
    scissor_enable=1;scissor_x=1;scissor_y=1;
    scissor_w=16'(FRAME_WIDTH);scissor_h=16'(FRAME_HEIGHT);
    do_tri(-16'sd6,-16'sd6,16'sd18,-16'sd6,-16'sd6,16'sd18);
    depth_compare_op=2;depth_write=0;blend_enable=1;source_alpha=8'd230;
    do_tri(-16'sd6,-16'sd6,-16'sd6,16'sd18,16'sd18,-16'sd6);
    scissor_enable=0;blend_enable=0;depth_compare_op=0;
    do_tri(0,0,0,0,0,0); // zero-area
    // Mid-command shared reset aborts outstanding raster and framebuffer.
    @(negedge clk);
    if(!a_tri_ready || !b_tri_ready) $fatal(1,"P137 pre-reset tri not ready");
    x0=-8;y0=-8;x1=20;y1=-8;x2=-8;y2=20;tri_valid=1;
    @(negedge clk);
    tri_valid=0;
    repeat(3) @(negedge clk);
    rst_n=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    do_clear(24'h010203,24'hffffff);
    tri_color=24'h998877;tri_depth=24'h000007;
    do_tri(-16'sd5,-16'sd5,16'sd20,-16'sd5,-16'sd5,16'sd20);
    if(clears!=2 || draws!=5 || pixel_writes<5 || reads<100)
      $fatal(1,"P137 vacuous coverage clears=%0d draws=%0d writes=%0d reads=%0d",
         clears,draws,pixel_writes,reads);
    $display("P137_LINEAR_FRAMEBUFFER_DIFFERENTIAL_PASS width=%0d height=%0d cycles=%0d clears=%0d draws=%0d pixel_writes=%0d",
      FRAME_WIDTH,FRAME_HEIGHT,checks,clears,draws,pixel_writes);
    $finish;
  end
  initial begin
    #3000000;
    $fatal(1,"P137 differential RTL watchdog");
  end
endmodule
