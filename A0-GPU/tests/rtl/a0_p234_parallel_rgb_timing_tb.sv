`timescale 1ns/1ps
// P234 full actual dot-clock raster: independent reference checks every
// pixel position, sync polarity, RGB bar and blanking across one full frame.
// Clock period is a *simulation* period; real 25.175/40 MHz requires an
// external board-specific clock resource not implemented here.
module a0_p234_parallel_rgb_timing_tb #(
    parameter integer MODE=0
);
  localparam integer HA=MODE==0 ? 640:800;
  localparam integer HF=MODE==0 ? 16:40;
  localparam integer HS=MODE==0 ? 96:128;
  localparam integer HB=MODE==0 ? 48:88;
  localparam integer VA=MODE==0 ? 480:600;
  localparam integer VF=MODE==0 ? 10:1;
  localparam integer VS=MODE==0 ? 2:4;
  localparam integer VB=MODE==0 ? 33:23;
  localparam integer HT=HA+HF+HS+HB,VT=VA+VF+VS+VB;
  localparam logic IDLE=MODE==0;
  logic pixel_clk=0,clk_running=1,rst_n=0,clock_locked=0;
  wire [23:0] rgb;wire de,hsync,vsync;
  a0_p234_parallel_rgb_timing #(.MODE(MODE)) dut(
    .pixel_clk(pixel_clk),.raw_rst_n(rst_n),.clock_locked(clock_locked),
    .rgb888(rgb),.video_de(de),.video_hsync(hsync),.video_vsync(vsync)
  );
  always #5 pixel_clk=clk_running ? ~pixel_clk : 1'b0;
  function automatic [23:0] expected_color(input integer x);
    integer stripe;
    begin
      stripe=x/(HA/8);
      case(stripe)
        0:expected_color=24'hffffff;
        1:expected_color=24'hffff00;
        2:expected_color=24'h00ffff;
        3:expected_color=24'h00ff00;
        4:expected_color=24'hff00ff;
        5:expected_color=24'hff0000;
        6:expected_color=24'h0000ff;
        default:expected_color=24'h000000;
      endcase
    end
  endfunction
  integer active_samples=0,blank_samples=0,h_sync_samples=0,v_sync_samples=0;
  task automatic verify_complete_frame;
    integer x,y;
    logic exp_de,exp_hs,exp_vs;
    logic [23:0] exp_rgb;
    begin
      for(y=0;y<VT;y=y+1)begin
        for(x=0;x<HT;x=x+1)begin
          #1;
          exp_de=(x<HA && y<VA);
          exp_hs=(MODE==0) ? !(x>=HA+HF && x<HA+HF+HS)
                           :  (x>=HA+HF && x<HA+HF+HS);
          exp_vs=(MODE==0) ? !(y>=VA+VF && y<VA+VF+VS)
                           :  (y>=VA+VF && y<VA+VF+VS);
          exp_rgb=exp_de ? expected_color(x):24'd0;
          if(dut.h_q!==11'(x) || dut.v_q!==10'(y) ||
             de!==exp_de || hsync!==exp_hs || vsync!==exp_vs ||
             rgb!==exp_rgb)
            $fatal(1,"P234 frame mismatch mode=%0d x=%0d y=%0d h=%0d v=%0d de=%b/%b hs=%b/%b vs=%b/%b rgb=%h/%h",
              MODE,x,y,dut.h_q,dut.v_q,de,exp_de,hsync,exp_hs,vsync,exp_vs,rgb,exp_rgb);
          if(exp_de)active_samples=active_samples+1;
          else blank_samples=blank_samples+1;
          if(x>=HA+HF && x<HA+HF+HS)h_sync_samples=h_sync_samples+1;
          if(y>=VA+VF && y<VA+VF+VS)v_sync_samples=v_sync_samples+1;
          @(negedge pixel_clk);
        end
      end
    end
  endtask
  task automatic require_disabled;
    begin
      #1;
      if(rgb!==24'd0 || de!==1'b0 ||
         hsync!==IDLE || vsync!==IDLE)
        $fatal(1,"P234 async lock/reset failed closed mode=%0d rgb=%h de=%b hs=%b vs=%b",
          MODE,rgb,de,hsync,vsync);
    end
  endtask
  initial begin
    if(MODE<0 || MODE>1)$fatal(1,"invalid P234 test mode");
    // Lock must be real input and remain absent at initial reset release.
    repeat(3)@(negedge pixel_clk);
    rst_n=1;
    repeat(3)@(negedge pixel_clk);
    require_disabled();
    clock_locked=1;
    @(posedge pixel_clk);#1;require_disabled(); // 1st qualification edge
    @(posedge pixel_clk);#1;
    if(!de || rgb!==24'hffffff || dut.h_q!==0 || dut.v_q!==0)
      $fatal(1,"P234 did not start at pixel 0 after two clock edges");
    @(negedge pixel_clk);
    verify_complete_frame();

    if(active_samples!=HA*VA || blank_samples!=(HT*VT-HA*VA) ||
       h_sync_samples!=HS*VT || v_sync_samples!=VS*HT)
      $fatal(1,"P234 missing frame pixels/sync pulses mode=%0d",MODE);
    if(!de || rgb!==24'hffffff)
      $fatal(1,"P234 failed to wrap to first active pixel");

    // Both real clocks stopped while RGB is nonzero: drop PLL lock. The
    // output must blank *without an edge*, then stay blank during restart
    // qualification even when lock rises while the clock is stopped.
    clk_running=0;
    #17;
    if(!de || rgb!==24'hffffff)
      $fatal(1,"P234 did not hold live pixel with stopped clock");
    clock_locked=0;
    require_disabled();
    clock_locked=1;
    #17;
    require_disabled();
    clk_running=1;
    @(posedge pixel_clk);#1;require_disabled();
    @(posedge pixel_clk);#1;
    if(!de || rgb!==24'hffffff || dut.h_q!==0 || dut.v_q!==0)
      $fatal(1,"P234 lock return failed to restart first pixel");
    @(negedge pixel_clk);
    verify_complete_frame();

    // Repeat with a raw asynchronous two-nanosecond reset pulse while
    // stopped on a live pixel, shorter than the simulated clock period.
    clk_running=0;
    #17;
    if(!de || rgb!==24'hffffff)
      $fatal(1,"P234 no nonzero pixel before short reset");
    rst_n=0;
    require_disabled();
    #1 rst_n=1;
    #17;require_disabled();
    clk_running=1;
    @(posedge pixel_clk);#1;require_disabled();
    @(posedge pixel_clk);#1;
    if(!de || rgb!==24'hffffff || dut.h_q!==0 || dut.v_q!==0)
      $fatal(1,"P234 short raw reset failed to restart");
    @(negedge pixel_clk);
    verify_complete_frame();
    $display("P234_FULL_TIMING_PASS mode=%0d active=%0d blank=%0d hsync=%0d vsync=%0d full_frames=3 locked_reset=1 stopped_clock_async_reset=1 2ns_pulse=1 colorbars=8",
      MODE,active_samples,blank_samples,h_sync_samples,v_sync_samples);
    $finish;
  end
  initial begin #50000000;$fatal(1,"P234 bounded real full-frame timeout mode=%0d",MODE);end
endmodule
