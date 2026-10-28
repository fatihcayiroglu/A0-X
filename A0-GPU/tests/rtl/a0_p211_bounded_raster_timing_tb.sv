`timescale 1ns/1ps
// P211 real P203->P210 EBR chain plus free-running raster and underflow.
module a0_p211_bounded_raster_timing_tb #(
  parameter integer WORDS=8,
  parameter integer FAST=0
);
  localparam integer W=(WORDS==8)?4:32;
  localparam integer H=WORDS/W;
  localparam integer HF=8,HS=4,HB=8,VF=2,VS=2,VB=2;
  localparam integer HT=W+HF+HS+HB,VT=H+VF+VS+VB;
  localparam integer DIV=FAST?1:64;
  localparam logic [31:0] BASE=32'h01000000;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,fault,busy,underflow,pixel_ce,video_de;
  wire video_hsync,video_vsync;
  wire [7:0] host_rdata;
  wire [47:0] video_pixel;
  logic producer_done=0;
  integer wall_cycles=0,last_ce_cycle=-1;
  always @(posedge clk)wall_cycles=wall_cycles+1;
  a0_p211_bounded_raster_timing #(
    .H_ACTIVE(W),.V_ACTIVE(H),.H_FRONT(HF),.H_SYNC(HS),
    .H_BACK(HB),.V_FRONT(VF),.V_SYNC(VS),.V_BACK(VB),
    .PIXEL_DIV(DIV),.RESPONSE_TIMEOUT(256)
  ) dut (
    .clk(clk),.rst_n(rst_n),.host_valid(host_valid),
    .host_write(host_write),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_ready(host_ready),
    .host_rdata(host_rdata),.fault(fault),.busy(busy),
    .underflow(underflow),.pixel_ce(pixel_ce),.video_de(video_de),
    .video_hsync(video_hsync),.video_vsync(video_vsync),
    .video_pixel(video_pixel)
  );
  function automatic [47:0] expected(input integer bank,input integer addr);
    expected={bank ? 16'hb19a : 16'h3e5f,16'(addr),16'(addr ^ 16'ha53c)};
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] data);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=data;
      #1;if(!host_ready)$fatal(1,"P211 host write blocked a=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] data);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P211 host read blocked a=%h",a);
      data=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic boot;
    integer n;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;
      producer_done=0;last_ce_cycle=-1;
      repeat(3)@(negedge clk);rst_n=1;
      n=0;
      while(busy && n<WORDS+200)begin @(negedge clk);n=n+1;end
      if(busy || fault || underflow || pixel_ce || video_de || n<WORDS)
        $fatal(1,"P211 reset did not scrub physical frame memories");
    end
  endtask
  task automatic write_word(input logic [31:0] addr,
                            input logic [47:0] word);
    logic [7:0] st;
    integer n,j;
    begin
      hw(6'h02,8'h01);
      for(j=0;j<4;j=j+1)hw(6'h04+6'(j),addr[j*8+:8]);
      for(j=0;j<6;j=j+1)hw(6'h08+6'(j),word[j*8+:8]);
      hw(6'h00,8'h01);
      st=0;n=0;
      while(!st[3] && n<180)begin
        hr(6'h01,st);n=n+1;
        if(st[4] || fault)$fatal(1,"P211 backend committed-write fault");
      end
      if(!st[3] || n<3)$fatal(1,"P211 no committed write ack");
      hr(6'h16,st);
      if(st[0])$fatal(1,"P211 backend write error");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic check_frame(input integer bank,input integer epoch);
    integer x,y,k,n;
    logic active,hs_expected,vs_expected;
    begin
      for(y=0;y<VT;y=y+1)begin
        for(x=0;x<HT;x=x+1)begin
          n=0;
          @(negedge clk);
          while(!pixel_ce && n<DIV+100)begin @(negedge clk);n=n+1;end
          if(!pixel_ce || fault || underflow)
            $fatal(1,"P211 timing halted/underflow bank=%0d x=%0d y=%0d",bank,x,y);
          if(last_ce_cycle>=0 && wall_cycles-last_ce_cycle!=DIV)
            $fatal(1,"P211 pixel clock-enable irregular %0d",wall_cycles-last_ce_cycle);
          last_ce_cycle=wall_cycles;
          active=(x<W && y<H);
          hs_expected=!(x>=W+HF && x<W+HF+HS);
          vs_expected=!(y>=H+VF && y<H+VF+VS);
          if(video_hsync!==hs_expected || video_vsync!==vs_expected ||
             video_de!==active)
            $fatal(1,"P211 wrong HS/VS/DE bank=%0d x=%0d y=%0d hs=%b vs=%b de=%b",
              bank,x,y,video_hsync,video_vsync,video_de);
          if(active)begin
            k=y*W+x;
            if(video_pixel!==expected(bank,k) ||
               dut.held_epoch_q!==32'(epoch))
              $fatal(1,"P211 torn/misordered raster bank=%0d index=%0d pixel=%h epoch=%0d",
                bank,k,video_pixel,dut.held_epoch_q);
            if(bank==0 && k==WORDS-2 &&
               (!producer_done || !dut.stream.publish_queued_q))
              $fatal(1,"P211 queued next frame was not ready before old last pixel");
          end else if(video_pixel!==48'd0)
            $fatal(1,"P211 data leaked into horizontal/vertical blanking");
        end
      end
    end
  endtask
  integer i,n;
  initial begin
    boot();
    // Negative: an incomplete frame must fault before video is enabled.
    write_word(BASE,expected(0,0));
    hw(6'h31,8'h01);
    repeat(12)@(negedge clk);
    if(!fault || video_de || pixel_ce)
      $fatal(1,"P211 incomplete frame escaped publication fence");
    boot();
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,expected(0,i));
    hw(6'h31,8'h01);
    n=0;
    while(!dut.run_q && n<2000)begin @(negedge clk);n=n+1;end
    if(!dut.run_q || fault)$fatal(1,"P211 first real EBR frame did not start");
    if(FAST!=0)begin
      n=0;
      while(!underflow && n<100)begin @(negedge clk);n=n+1;end
      if(!underflow || !fault)$fatal(1,"P211 fast clock did not detect actual underflow");
      repeat(12)begin
        @(negedge clk);
        if(video_de || video_pixel!==48'd0)
          $fatal(1,"P211 post-underflow video leaked frame data");
      end
      boot();
      if(underflow || video_de || video_pixel!==48'd0)
        $fatal(1,"P211 underflow not cleared by reset");
      $display("P211_TIMING_UNDERFLOW_PASS words=%0d div=1 sticky=1 black=1 reset=1",WORDS);
      $finish;
    end
    fork
      begin : producer
        hw(6'h30,8'h01);
        for(integer b=0;b<WORDS;b=b+1)
          write_word(BASE+WORDS+b,expected(1,b));
        hw(6'h31,8'h01);
        producer_done=1;
      end
      begin : raster
        check_frame(0,1);
        check_frame(1,2);
      end
    join
    // A published front must remain immutable even in the raster wrapper.
    hw(6'h02,8'h01);
    repeat(3)@(negedge clk);
    if(!fault || video_de)
      $fatal(1,"P211 missed write-lock fault");
    boot();
    if(dut.stream.scanout.shadow0[0]!==48'd0 ||
       dut.stream.scanout.shadow1[0]!==48'd0)
      $fatal(1,"P211 stale physical front leaked after reset scrub");
    $display("P211_RASTER_TIMING_PASS words=%0d div=%0d frames=2 epochs=2 hsync=1 vsync=1 hblank=1 vblank=1 continuous_ce=1 queued_fence=1 front_lock=1 reset_scrub=1",WORDS,DIV);
    $finish;
  end
  initial begin #600000000;$fatal(1,"P211 bounded raster proof timeout");end
endmodule
