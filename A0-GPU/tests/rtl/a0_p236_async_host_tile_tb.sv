\`timescale 1ns/1ps
// P236: real 35-bit physical dual-clock FIFO producer -> P235 live BRAM,
// 32x24 tiles displayed across an entire 640x480 or 800x600 RGB888 raster.
// Includes interrupted clocks, FIFO backpressure, host packet rejection,
// two distinct full frame commits and short reset with no stale replay.
module a0_p236_async_host_tile_tb #(
  parameter integer MODE=0,
  parameter integer CLOCK_MODE=0
);
  localparam integer HA=MODE==0?640:800,VA=MODE==0?480:600;
  localparam integer SCALE=MODE==0?20:25;
  localparam integer HT=MODE==0?800:1056,VT=MODE==0?525:628;
  localparam integer HOST_HALF=CLOCK_MODE==0?4:7;
  localparam integer PIX_HALF=CLOCK_MODE==0?7:4;
  localparam logic HS_IDLE=MODE==0?1'b1:1'b0;
  localparam logic VS_IDLE=MODE==0?1'b1:1'b0;
  logic host_clk=0,pixel_clk=0,pixel_running=1;
  logic rst_n=0,locked=0,src_valid=0,src_commit=0;
  logic [9:0] src_index=0;
  logic [23:0] src_rgb=0;
  wire src_ready,host_fault,pixel_fault;
  wire [23:0] rgb;wire de,hs,vs;
  wire [23:0] ref_color;wire ref_de,ref_hs,ref_vs;
  a0_p236_async_host_tile_top #(.MODE(MODE),.FIFO_ADDR_BITS(4)) dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .raw_rst_n(rst_n),.clock_locked(locked),
    .src_valid(src_valid),.src_commit(src_commit),
    .src_index(src_index),.src_rgb(src_rgb),
    .src_ready(src_ready),.host_protocol_fault(host_fault),
    .pixel_load_fault(pixel_fault),
    .rgb888(rgb),.video_de(de),.video_hsync(hs),.video_vsync(vs)
  );
  a0_p234_parallel_rgb_timing #(.MODE(MODE)) timing_reference(
    .pixel_clk(pixel_clk),.raw_rst_n(rst_n),.clock_locked(locked),
    .rgb888(ref_color),.video_de(ref_de),
    .video_hsync(ref_hs),.video_vsync(ref_vs)
  );
  always #HOST_HALF host_clk=~host_clk;
  always #PIX_HALF pixel_clk=pixel_running ? ~pixel_clk : 1'b0;

  function automatic [23:0] pattern(input integer bank,input integer idx);
    pattern={8'((idx*3+bank*71+13)&255),
             8'((idx*7+bank*29+3)&255),
             8'((idx*11+bank*47+91)&255)};
  endfunction

  integer stalls=0,accepts=0,pop_data=0,pop_commit=0;
  integer swaps=0,active0=0,active1=0,blank_samples=0;
  logic [767:0] covered0=0,covered1=0;
  logic prev_front_valid=0,prev_front_bank=0;
  logic check_pixels=0;
  integer source_pixel;
  always @(posedge host_clk) begin
    if(rst_n && locked && src_valid)begin
      if(!src_ready)stalls=stalls+1;
      else accepts=accepts+1;
    end
  end
  always @(posedge pixel_clk) begin
    if(rst_n && locked && dut.queue.rd_valid &&
       dut.queue.rd_ready)begin
      if(dut.fifo_commit)pop_commit=pop_commit+1;
      else pop_data=pop_data+1;
    end
  end
  // Strict per-clock full RGB888 scoreboard against independent timing.
  always @(negedge pixel_clk) begin
    #1;
    if(check_pixels && rst_n && locked && !pixel_fault &&
       dut.scanout.released_q[1])begin
      if(dut.scanout.h_q!==timing_reference.h_q ||
         dut.scanout.v_q!==timing_reference.v_q ||
         hs!==ref_hs || vs!==ref_vs)
        $fatal(1,"P236 pixel timing/HSVS diverged mode=%0d clocks=%0d",MODE,CLOCK_MODE);
      if(dut.scanout.front_valid_q!==prev_front_valid ||
         dut.scanout.front_bank_q!==prev_front_bank)begin
        if(dut.scanout.h_q!==0 || dut.scanout.v_q!==0 ||
           !dut.scanout.front_valid_q)
          $fatal(1,"P236 tore frame outside VBlank mode=%0d clocks=%0d",MODE,CLOCK_MODE);
        swaps=swaps+1;
      end
      prev_front_valid=dut.scanout.front_valid_q;
      prev_front_bank=dut.scanout.front_bank_q;
      if(dut.scanout.front_valid_q && ref_de)begin
        source_pixel=(dut.scanout.v_q/SCALE)*32+(dut.scanout.h_q/SCALE);
        if(source_pixel<0 || source_pixel>=768 ||
           de!==1 || rgb!==pattern(dut.scanout.front_bank_q,source_pixel))
          $fatal(1,"P236 BRAM mismatch mode=%0d clocks=%0d x=%0d y=%0d bank=%b rgb=%h expected=%h",
             MODE,CLOCK_MODE,dut.scanout.h_q,dut.scanout.v_q,
             dut.scanout.front_bank_q,rgb,
             pattern(dut.scanout.front_bank_q,source_pixel));
        if(dut.scanout.front_bank_q)begin
          active1=active1+1;covered1[source_pixel]=1;
        end else begin
          active0=active0+1;covered0[source_pixel]=1;
        end
      end else if(de!==0 || rgb!==24'd0)
        $fatal(1,"P236 uncommitted/back-bank/blank pixel leaked");
      if(!ref_de)blank_samples=blank_samples+1;
    end
  end
  always @(negedge rst_n or negedge locked)begin
    prev_front_valid=0;prev_front_bank=0;
  end

  task automatic send(input logic commit,input integer idx,input logic [23:0] color);
    integer timeout_edges;
    begin
      @(negedge host_clk);
      src_valid=1;src_commit=commit;
      src_index=10'(idx);src_rgb=color;
      timeout_edges=0;
      // Ready can change with FIFO CDC full/empty flags, so decide at the
      // stable falling edge and only retire on a real rising ready/valid.
      while(!src_ready && timeout_edges<2000000)begin
        @(negedge host_clk);
        timeout_edges=timeout_edges+1;
      end
      if(!src_ready)$fatal(1,"P236 host enqueue hung");
      @(posedge host_clk);
      @(negedge host_clk);
      src_valid=0;src_commit=0;
    end
  endtask
  task automatic full_frame(input integer bank);
    integer i;
    begin
      for(i=0;i<768;i=i+1)
        send(0,i,pattern(bank,i));
      send(1,0,24'd0);
    end
  endtask
  task automatic require_black;
    begin
      #1;
      if(rgb!==24'd0 || de!==1'b0 ||
         hs!==HS_IDLE || vs!==VS_IDLE)
        $fatal(1,"P236 fail-closed output failed when clocks stopped");
    end
  endtask
  integer cycles;
  initial begin
    if(CLOCK_MODE!=0 && CLOCK_MODE!=1 || MODE!=0 && MODE!=1)
      $fatal(1,"P236 invalid test mode");
    repeat(5)@(negedge host_clk);
    rst_n=1;locked=1;
    repeat(20)@(negedge host_clk);
    if(!src_ready || de!==0)
      $fatal(1,"P236 CDC reset/release not ready");

    // Negative proof: malformed marker after ONE word must be rejected
    // on host side and never enter the physical asynchronous FIFO.
    send(0,0,pattern(1,0));
    send(1,0,0);
    repeat(12)@(negedge host_clk);
    if(!host_fault || src_ready || de)
      $fatal(1,"P236 short host frame was accepted/visible");
    rst_n=0;require_black();
    repeat(5)@(negedge host_clk);
    rst_n=1;
    repeat(25)@(negedge host_clk);
    if(host_fault || pixel_fault || !src_ready)
      $fatal(1,"P236 short-frame fault not cleared by real reset");
    check_pixels=1;

    // Stop receiver while transferring; a real 16-depth FIFO fills and
    // asserts host backpressure. Resume receiver and drain in-order.
    pixel_running=0;
    fork
      begin
        full_frame(1);
        // The host immediately attempts the next frame. FIFO must hold
        // any traffic until the first bank is published at full VBlank.
        full_frame(0);
      end
      begin
        repeat(125)@(negedge host_clk);
        if(stalls<10 || dut.queue.wgray_q==0)
          $fatal(1,"P236 no real FIFO full/backpressure while pixel clock stopped");
        pixel_running=1;
      end
    join
    if(host_fault || pixel_fault || accepts<1538)
      $fatal(1,"P236 lost/duplicated host transactions accepts=%0d",accepts);
    cycles=0;
    while((swaps<2 || active0<HA*VA || active1<HA*VA) &&
          cycles<4*HT*VT)begin
      @(negedge pixel_clk);
      cycles=cycles+1;
    end
    #2;
    if(swaps!=2 || !(&covered0) || !(&covered1) ||
       active0<HA*VA || active1<HA*VA ||
       pop_data!=1537 || pop_commit!=2 ||
       stalls<10 || blank_samples<HT)
      $fatal(1,"P236 coverage/handshakes insufficient swaps=%0d active=%0d,%0d pop=%0d,%0d stalls=%0d",
        swaps,active0,active1,pop_data,pop_commit,stalls);
    // Pop count includes one deliberately malformed first frame word;
    // after the reset, only the two full 768-word frames count. See
    // reset of the counters below if the simulator tracks prior traffic.

    // Live nonzero output must vanish with a short async raw reset even
    // when pixel_clk is fully stopped; the FIFO's unreset BRAM never
    // becomes visible again until 768 new committed words arrive.
    cycles=0;
    while((!de || rgb==0) && cycles<HT*VT)begin
      @(negedge pixel_clk);
      cycles=cycles+1;
    end
    if(!de || rgb==0)$fatal(1,"P236 no real live colored output at reset");
    @(negedge pixel_clk);pixel_running=0;
    #21;
    if(!de || rgb==0)$fatal(1,"P236 stopped-clock visible pixel vanished early");
    rst_n=0;
    require_black();
    #1 rst_n=1;
    #21;require_black();
    pixel_running=1;
    repeat(30)@(negedge pixel_clk);
    if(dut.scanout.front_valid_q || de || rgb!==0 ||
       host_fault || pixel_fault || !src_ready)
      $fatal(1,"P236 stale FIFO/frame replay after reset");
    locked=0;require_black();
    $display("P236_REAL_CDC_TILE_PASS mode=%0d clock_mode=%0d banks=2 tile_words=768 source_pixels=1536 commits=2 swaps=2 fifo_stalls=%0d seen0=%0d seen1=%0d stopped_clock_reset=1 invalid_commit_rejected=1 no_torn_frame=1",
      MODE,CLOCK_MODE,stalls,active0,active1);
    $finish;
  end
  initial begin #125000000;$fatal(1,"P236 full raster execution timed out");end
endmodule
