`timescale 1ns/1ps
// P235: exhaustive actual 32x24 BRAM tile upscale for two standard modes.
// Writes TWO different 768-color tiles to inactive banks and verifies all
// 640x480 / 800x600 DE, RGB888, porch and HS/VS pixel outputs against an
// independent P234 timing instance. No synthetic pass marker without full
// reference coverage. This is one pixel clock, not a host CDC integration.
module a0_p235_scaled_bram_rgb_tb #(parameter integer MODE=0);
  localparam integer HA=MODE==0?640:800;
  localparam integer VA=MODE==0?480:600;
  localparam integer HF=MODE==0?16:40;
  localparam integer HS=MODE==0?96:128;
  localparam integer HB=MODE==0?48:88;
  localparam integer VF=MODE==0?10:1;
  localparam integer VS=MODE==0?2:4;
  localparam integer VB=MODE==0?33:23;
  localparam integer HT=HA+HF+HS+HB,VT=VA+VF+VS+VB;
  localparam integer SCALE=MODE==0?20:25;
  localparam integer TOTAL_PIX=768;
  localparam logic HS_IDLE=MODE==0?1'b1:1'b0;
  localparam logic VS_IDLE=MODE==0?1'b1:1'b0;
  logic clk=0,clock_running=1,rst_n=0,lock=0;
  logic load_valid=0,commit_valid=0;
  logic [9:0] load_index=0;
  logic [23:0] load_rgb=0;
  wire ready,commit_ready,fault,de,hs,vs;
  wire [23:0] rgb;
  wire [23:0] ignored_ref_rgb;
  wire ref_de,ref_hs,ref_vs;
  a0_p235_scaled_bram_rgb #(.MODE(MODE)) dut (
    .pixel_clk(clk),.raw_rst_n(rst_n),.clock_locked(lock),
    .load_valid(load_valid),.load_index(load_index),.load_rgb(load_rgb),
    .load_ready(ready),.commit_valid(commit_valid),
    .commit_ready(commit_ready),.load_fault(fault),
    .rgb888(rgb),.video_de(de),.video_hsync(hs),.video_vsync(vs)
  );
  a0_p234_parallel_rgb_timing #(.MODE(MODE)) reference(
    .pixel_clk(clk),.raw_rst_n(rst_n),.clock_locked(lock),
    .rgb888(ignored_ref_rgb),.video_de(ref_de),
    .video_hsync(ref_hs),.video_vsync(ref_vs)
  );
  always #5 clk=clock_running ? ~clk:1'b0;

  function automatic [23:0] color(input integer bank,input integer idx);
    begin
      // Distinct full RGB patterns. Indices cover 32 columns / 24 rows;
      // per-bank R/G/B data all vary and cannot be replaced by colorbars.
      color={8'((idx*3+bank*71+13)&255),
             8'((idx*7+bank*29+3)&255),
             8'((idx*11+bank*47+91)&255)};
    end
  endfunction
  integer observed0=0,observed1=0,blanked=0,failed_samples=0;
  integer front_swaps=0,first_frame_samples=0;
  logic old_front_bank=0,old_front_valid=0;
  logic [767:0] touched0=0,touched1=0;
  logic guard_enable=0;
  // Reset or loss of pixel-clock lock invalidates the *previous run's*
  // front-bank comparison baseline. A normal reset is not a torn frame.
  always @(negedge rst_n or negedge lock) begin
    old_front_valid=0;
    old_front_bank=0;
  end
  integer monitor_index;
  // Observe every pixel, not just the frames around the successful commit.
  // A later front-bank swap outside x=y=0, a wrong scaled tile index or a
  // stale uncommitted bank is immediately fatal.
  always @(negedge clk) begin
    #1;
    if(rst_n && lock && !fault &&
       dut.released_q[1] && guard_enable) begin
      if(dut.h_q!==reference.h_q || dut.v_q!==reference.v_q)
        $fatal(1,"P235 local BRAM address raster drifted from P234 timing");
      if(hs!==ref_hs || vs!==ref_vs)
        $fatal(1,"P235 HS/VS deviated from independent P234 mode=%0d",MODE);
      if(dut.front_valid_q!==old_front_valid ||
         dut.front_bank_q!==old_front_bank) begin
        if(dut.h_q!=0 || dut.v_q!=0)
          $fatal(1,"P235 non-VBlank/partial front bank swap");
        if(!dut.front_valid_q)
          $fatal(1,"P235 published front became invalid");
        front_swaps=front_swaps+1;
      end
      old_front_valid=dut.front_valid_q;
      old_front_bank=dut.front_bank_q;
      if(dut.front_valid_q && ref_de) begin
        monitor_index=(dut.v_q/SCALE)*32+(dut.h_q/SCALE);
        if(monitor_index<0 || monitor_index>=TOTAL_PIX)
          $fatal(1,"P235 scaled source BRAM index out of bounds");
        if(de!==1 || rgb!==color(dut.front_bank_q,monitor_index))
          $fatal(1,"P235 unexpected BRAM RGB mode=%0d pos=%0d,%0d bank=%0d rgb=%h expected=%h",
                 MODE,dut.h_q,dut.v_q,dut.front_bank_q,rgb,
                 color(dut.front_bank_q,monitor_index));
        if(dut.front_bank_q)begin
          observed1=observed1+1;touched1[monitor_index]=1;
        end else begin
          observed0=observed0+1;touched0[monitor_index]=1;
        end
      end else if(de!==0 || rgb!==24'd0)
        $fatal(1,"P235 data leaked before commit or through blanking");
      if(!ref_de)blanked=blanked+1;
    end
  end

  task automatic write_one(input integer idx,input integer bank);
    begin
      @(negedge clk);
      if(!ready || fault || dut.stage_valid_q)
        $fatal(1,"P235 load not ready bank=%0d index=%0d",bank,idx);
      load_valid=1;
      load_index=10'(idx);
      load_rgb=color(bank,idx);
      @(negedge clk);
      load_valid=0;
      #1; // allow ready/commit_ready combinational logic to settle after deassertion
      if(dut.load_count_q!=10'(idx+1))
        $fatal(1,"P235 committed memory write counter incorrect index=%0d",idx);
    end
  endtask
  task automatic commit_whole;
    begin
      @(negedge clk);
      if(!commit_ready || fault || !ready && dut.load_count_q!=TOTAL_PIX)
        $fatal(1,"P235 full tile not ready to commit");
      commit_valid=1;
      @(negedge clk);
      commit_valid=0;
      if(!dut.stage_valid_q || !dut.front_valid_q && dut.front_bank_q!=0)
        $fatal(1,"P235 full tile not staged");
    end
  endtask
  task automatic release_after_reset;
    begin
      repeat(3)@(negedge clk);
      rst_n=1;lock=1;
      repeat(5)@(negedge clk);
      if(fault || !ready || dut.front_valid_q || de || rgb!==24'd0)
        $fatal(1,"P235 reset did not start hidden with back bank ready");
    end
  endtask
  task automatic require_dark;
    begin
      #1;
      if(rgb!==24'd0 || de!==0 || hs!==HS_IDLE || vs!==VS_IDLE)
        $fatal(1,"P235 immediate fail-closed reset/lock blanking failed");
    end
  endtask
  integer i,cycles;
  initial begin
    // Reject a partial commit after just one REAL BRAM write.
    release_after_reset();
    write_one(0,1);
    @(negedge clk);
    if(commit_ready)$fatal(1,"P235 prematurely ready after one pixel");
    commit_valid=1;
    @(negedge clk);commit_valid=0;
    if(!fault || de || rgb!==24'd0)
      $fatal(1,"P235 early publication was not fail-closed");
    lock=0;require_dark();
    repeat(3)@(negedge clk);
    rst_n=0;require_dark();
    repeat(3)@(negedge clk);
    release_after_reset();
    guard_enable=1;

    // Complete bank1: 768 genuine write transactions (not an initialized
    // ROM), independently checked by counter. It must remain hidden until
    // the last VBlank wrap.
    for(i=0;i<TOTAL_PIX;i=i+1)write_one(i,1);
    #1;
    if(!commit_ready || dut.front_valid_q)
      $fatal(1,"P235 first full tile state commit_ready=%b front_valid=%b count=%0d stage=%b",commit_ready,dut.front_valid_q,dut.load_count_q,dut.stage_valid_q);
    commit_whole();
    cycles=0;
    while(!dut.front_valid_q && cycles<HT*VT+10)begin
      @(negedge clk);cycles=cycles+1;
    end
    #2; // allow the independent negedge RGB coverage monitor to sample pixel 0
    if(!dut.front_valid_q || dut.front_bank_q!==1 || !touched1[0])
      $fatal(1,"P235 first tile not published on VBlank");
    // Write the other bank while bank1 is ACTIVELY scanned; all visible
    // pixels are covered continuously by the independent scoreboard.
    for(i=0;i<TOTAL_PIX;i=i+1)write_one(i,0);
    if(!commit_ready || dut.front_bank_q!==1 || fault)
      $fatal(1,"P235 writing back bank disturbed live front");
    commit_whole();
    cycles=0;
    while(dut.front_bank_q!==0 && cycles<HT*VT+10)begin
      @(negedge clk);cycles=cycles+1;
    end
    if(dut.front_bank_q!==0 || !dut.front_valid_q)
      $fatal(1,"P235 second tile not published atomically");
    // Walk a COMPLETE second frame, including all active and blank clocks.
    repeat(HT*VT+1)@(negedge clk);
    if(!(&touched0) || !(&touched1) || front_swaps!=2 ||
       observed0<HA*VA || observed1<HA*VA || blanked<HT)
      $fatal(1,"P235 coverage vacuous mode=%0d swaps=%0d active0=%0d active1=%0d",
        MODE,front_swaps,observed0,observed1);

    // Stop on a live nonzero pixel and assert a two-nanosecond raw reset:
    // no clock edge is available to clear public outputs.
    cycles=0;
    while((!de || rgb===24'd0) && cycles<HT*VT)begin
      @(negedge clk);cycles=cycles+1;
    end
    if(!de || rgb===24'd0)$fatal(1,"P235 no live nonzero pixel before reset");
    @(negedge clk);clock_running=0;
    #21;if(!de || rgb===24'd0)$fatal(1,"P235 stopped-clock live sample lost");
    rst_n=0;require_dark();
    #1 rst_n=1;
    #21;require_dark();
    // The clock must restart and locally requalify before any new front
    // can become visible. Old BRAM data still exists but is inaccessible.
    clock_running=1;
    repeat(5)@(negedge clk);
    if(dut.front_valid_q || de || rgb!==24'd0 || fault)
      $fatal(1,"P235 stale bank replay after stopped-clock reset");
    lock=0;require_dark();

    $display("P235_SCALED_BRAM_PASS mode=%0d tile=32x24 bank_words=768 distinct_banks=2 wraps=%0d touched_bank0=768 touched_bank1=768 active0=%0d active1=%0d incomplete_reject=1 frame_atomic=1 sync_reference=1 stopped_reset=1 bram_scrub_claim=0",
      MODE,front_swaps,observed0,observed1);
    $finish;
  end
  initial begin #120000000;$fatal(1,"P235 exhaustive full-frame simulation timeout mode=%0d",MODE);end
endmodule
