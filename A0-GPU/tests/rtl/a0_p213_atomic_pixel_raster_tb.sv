`timescale 1ns/1ps
// P213 end-to-end video in the independent pixel-clock domain over real EBRs.
module a0_p213_atomic_pixel_raster_tb #(
  parameter integer WORDS=8
);
  localparam integer W=(WORDS==8)?4:32;
  localparam integer H=WORDS/W;
  localparam integer HF=8,HS=4,HB=8,VF=2,VS=2,VB=2;
  localparam integer HT=W+HF+HS+HB,VT=H+VF+VS+VB,DIV=64;
  localparam logic [31:0] BASE=32'h01000000;
  logic host_clk=0,pixel_clk=0,rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,host_fault,host_busy,pixel_fault,pixel_ce,video_de;
  wire video_hsync,video_vsync;
  wire [7:0] host_rdata;
  wire [47:0] video_pixel;
  integer wall_cycles=0,last_tick=-1;
  always #4 host_clk=~host_clk;
  always #7 pixel_clk=~pixel_clk;
  always @(posedge pixel_clk)wall_cycles=wall_cycles+1;
  a0_p213_atomic_pixel_raster #(
    .H_ACTIVE(W),.V_ACTIVE(H),.H_FRONT(HF),.H_SYNC(HS),
    .H_BACK(HB),.V_FRONT(VF),.V_SYNC(VS),.V_BACK(VB),
    .PIXEL_DIV(DIV),.FIFO_ADDR_BITS(6),.RESPONSE_TIMEOUT(256)
  ) dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .host_fault(host_fault),.host_busy(host_busy),
    .pixel_fault(pixel_fault),.pixel_ce(pixel_ce),.video_de(video_de),
    .video_hsync(video_hsync),.video_vsync(video_vsync),
    .video_pixel(video_pixel)
  );
  function automatic [47:0] expected(input integer bank,input integer idx);
    expected={bank ? 16'hb19a : 16'h3e5f,16'(idx),16'(idx ^ 16'ha53c)};
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] data);
    begin
      @(negedge host_clk);host_valid=1;host_write=1;host_addr=a;host_wdata=data;
      #1;if(!host_ready)$fatal(1,"P213 host write not ready addr=%h",a);
      @(negedge host_clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] data);
    begin
      @(negedge host_clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P213 host read not ready addr=%h",a);
      data=host_rdata;
      @(negedge host_clk);host_valid=0;
    end
  endtask
  task automatic write_word(input logic [31:0] addr,
                            input logic [47:0] word);
    logic [7:0] st;integer n,j;
    begin
      hw(6'h02,8'h01);
      for(j=0;j<4;j=j+1)hw(6'h04+6'(j),addr[j*8+:8]);
      for(j=0;j<6;j=j+1)hw(6'h08+6'(j),word[j*8+:8]);
      hw(6'h00,8'h01);
      st=0;n=0;
      while(!st[3] && n<180)begin
        hr(6'h01,st);n=n+1;
        if(st[4] || host_fault)$fatal(1,"P213 backend committed write fault");
      end
      if(!st[3] || n<3)$fatal(1,"P213 no write COMMIT");
      hr(6'h16,st);
      if(st[0])$fatal(1,"P213 backend write failed");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic boot;
    integer n;
    begin
      @(negedge host_clk);rst_n=0;host_valid=0;host_write=0;last_tick=-1;
      repeat(3)@(negedge host_clk);rst_n=1;
      @(negedge host_clk);
      if(!dut.source.source.scanout.scanout.fault && !dut.source.source.scanout.busy)
        $fatal(1,"P213 physical reset scrub not observed");
      repeat(6)@(negedge pixel_clk);
      n=0;
      while(host_busy && n<WORDS+200)begin @(negedge host_clk);n=n+1;end
      if(host_fault || pixel_fault || pixel_ce || video_de ||
         video_pixel!==48'd0 || dut.front_valid_q)
        $fatal(1,"P213 stale video after reset");
    end
  endtask
  task automatic check_frame(input integer bank,input integer epoch);
    integer x,y,k,n;logic active,hs_e,vs_e;
    begin
      for(y=0;y<VT;y=y+1)begin
        for(x=0;x<HT;x=x+1)begin
          n=0;
          @(negedge pixel_clk);
          while(!pixel_ce && n<DIV+100)begin @(negedge pixel_clk);n=n+1;end
          if(!pixel_ce || host_fault || pixel_fault)
            $fatal(1,"P213 pixel clock stalled/fault x=%0d y=%0d",x,y);
          if(last_tick>=0 && wall_cycles-last_tick!=DIV)
            $fatal(1,"P213 nonperiodic pixel CE");
          last_tick=wall_cycles;
          active=(x<W && y<H);
          hs_e=!(x>=W+HF && x<W+HF+HS);
          vs_e=!(y>=H+VF && y<H+VF+VS);
          if(video_hsync!==hs_e || video_vsync!==vs_e ||
             video_de!==active)
            $fatal(1,"P213 sync or DE mismatch x=%0d y=%0d bank=%0d",x,y,bank);
          if(active)begin
            k=y*W+x;
            if(video_pixel!==expected(bank,k) ||
               dut.front_epoch_q!==32'(epoch))
              $fatal(1,"P213 torn VBlank frame bank=%0d index=%0d pixel=%h front_epoch=%0d",
                bank,k,video_pixel,dut.front_epoch_q);
          end else if(video_pixel!==48'd0)
            $fatal(1,"P213 leaked video through blanking");
        end
      end
    end
  endtask
  integer i,n;
  initial begin
    boot();
    // An incomplete physical source frame must be rejected before startup.
    write_word(BASE,expected(0,0));hw(6'h31,8'h01);
    repeat(12)@(negedge pixel_clk);
    if(!host_fault || !pixel_fault || pixel_ce || video_de)
      $fatal(1,"P213 incomplete source frame leaked");
    boot();
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,expected(0,i));
    hw(6'h31,8'h01);
    n=0;
    while(!dut.run_q && n<50000)begin @(negedge pixel_clk);n=n+1;end
    if(!dut.run_q || host_fault || pixel_fault)
      $fatal(1,"P213 first complete staged frame never became front");
    fork
      begin : producer
        hw(6'h30,8'h01);
        for(integer b=0;b<WORDS;b=b+1)
          write_word(BASE+WORDS+b,expected(1,b));
        hw(6'h31,8'h01);
      end
      begin : display
        check_frame(0,1);
        check_frame(1,2);
      end
    join
    if(dut.duplicate_frames_q==0)
      $fatal(1,"P213 did not demonstrate dropped duplicate epoch frames");
    // Strict front-lock survives independent pixel-domain publication.
    hw(6'h02,8'h01);
    repeat(6)@(negedge pixel_clk);
    if(!host_fault || !pixel_fault || video_de)
      $fatal(1,"P213 published front mutation not fatal/blank");
    boot();
    if(dut.front_valid_q || video_pixel!==48'd0)
      $fatal(1,"P213 pixel local BRAM became visible without fresh frame");
    $display("P213_ATOMIC_PIXEL_RASTER_PASS words=%0d frames=2 epochs=2 dual_clock=1 vblank_swap=1 no_torn_frame=1 duplicate_drops=%0d sync_blank=1 front_lock=1 reset_mask=1",
      WORDS,dut.duplicate_frames_q);
    $finish;
  end
  initial begin #800000000;$fatal(1,"P213 bounded real raster timeout");end
endmodule
