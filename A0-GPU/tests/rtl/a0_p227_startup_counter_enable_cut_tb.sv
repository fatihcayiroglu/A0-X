`timescale 1ns/1ps
// P227: end-to-end video over real EBRs with a registered FIFO-to-epoch
// ingress stage and two complete independent pixel-domain frame epochs.
module a0_p227_clock_skew_raster_tb #(
  parameter integer WORDS=8,
  parameter integer MODE=0
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
  // Distinct ratios and nonzero phase offsets exercise the complete EBR raster.
  localparam integer HOST_HALF=(MODE==0)?4:(MODE==1)?7:5;
  localparam integer PIXEL_HALF=(MODE==0)?7:(MODE==1)?4:6;
  logic host_clk_running=1,pixel_clk_running=1;
  always #(HOST_HALF) host_clk=host_clk_running ? ~host_clk : 1'b0;
  initial begin
    #(MODE+1);
    forever #(PIXEL_HALF) pixel_clk=pixel_clk_running ? ~pixel_clk : 1'b0;
  end
  always @(posedge pixel_clk)wall_cycles=wall_cycles+1;
  a0_p227_domain_local_reset_raster #(
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
      #1;if(!host_ready)$fatal(1,"P227 host write not ready addr=%h",a);
      @(negedge host_clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] data);
    begin
      @(negedge host_clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P227 host read not ready addr=%h",a);
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
        if(st[4] || host_fault)$fatal(1,"P227 backend committed write fault");
      end
      if(!st[3] || n<3)$fatal(1,"P227 no write COMMIT");
      hr(6'h16,st);
      if(st[0])$fatal(1,"P227 backend write failed");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic boot;
    integer n,k;
    begin
      @(negedge host_clk);rst_n=0;host_valid=0;host_write=0;last_tick=-1;
      repeat(3)@(negedge host_clk);rst_n=1;
      wait(dut.fabric_rst_n);
      if(!dut.host_rst_n || !dut.pixel_rst_n) $fatal(1,"P227 both reset domains must qualify");
      @(negedge host_clk);
      if(!dut.raster.source.source.busy)
        $fatal(1,"P227 physical reset scrub not observed");
      repeat(6)@(negedge pixel_clk);
      n=0;
      while(!dut.raster.scrub_done_q && n<WORDS+8)begin
        if(pixel_ce || video_de || video_pixel!==48'd0)
          $fatal(1,"P227 output enabled during physical EBR scrub");
        @(negedge pixel_clk);n=n+1;
      end
      if(!dut.raster.scrub_done_q || n<WORDS-8)
        $fatal(1,"P227 did not walk all EBR scrub addresses");
      for(k=0;k<WORDS;k=k+1)begin
        if(dut.raster.frame0[k]!==48'd0 || dut.raster.frame1[k]!==48'd0)
          $fatal(1,"P227 nonzero physical frame RAM after scrub addr=%0d",k);
      end
      n=0;
      while(host_busy && n<WORDS+200)begin @(negedge host_clk);n=n+1;end
      if(host_fault || pixel_fault || pixel_ce || video_de ||
         video_pixel!==48'd0 || dut.raster.front_valid_q)
        $fatal(1,"P227 stale video after reset");
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
            $fatal(1,"P227 pixel clock stalled/fault x=%0d y=%0d",x,y);
          if(last_tick>=0 && wall_cycles-last_tick!=DIV)
            $fatal(1,"P227 nonperiodic pixel CE");
          last_tick=wall_cycles;
          active=(x<W && y<H);
          hs_e=!(x>=W+HF && x<W+HF+HS);
          vs_e=!(y>=H+VF && y<H+VF+VS);
          if(video_hsync!==hs_e || video_vsync!==vs_e ||
             video_de!==active)
            $fatal(1,"P227 sync or DE mismatch x=%0d y=%0d bank=%0d",x,y,bank);
          if(active)begin
            k=y*W+x;
            if(video_pixel!==expected(bank,k) ||
               dut.raster.front_epoch_q!==32'(epoch))
              $fatal(1,"P227 torn VBlank frame bank=%0d index=%0d pixel=%h front_epoch=%0d",
                bank,k,video_pixel,dut.raster.front_epoch_q);
          end else if(video_pixel!==48'd0)
            $fatal(1,"P227 leaked video through blanking");
        end
      end
    end
  endtask
  integer prestart_hold_checks=0;
  // P227: startup counters remain at their reset values until run_q.
  always @(negedge pixel_clk) begin
    if(dut.pixel_rst_n && !dut.raster.run_q) begin
      if(dut.raster.h_q!==16'd0 || dut.raster.v_q!==16'd0 ||
         dut.raster.div_q!==16'd0)
        $fatal(1,"P227 startup counter moved without a published frame");
      prestart_hold_checks=prestart_hold_checks+1;
    end
  end
  integer invalid_guard_checks=0,stale_hold_samples=0;
  // P227 deliberately leaves old payload bits in the registered lane
  // while valid=0. They MUST NOT write either pixel bank or be consumed.
  always @(negedge pixel_clk)begin
    if(dut.pixel_rst_n && dut.raster.scrub_done_q &&
       !dut.raster.pipe_valid_q && !dut.raster.local_fault_q &&
       !dut.raster.src_fault)begin
      if(dut.raster.consume || dut.raster.bank0_write ||
         dut.raster.bank1_write)
        $fatal(1,"P227 stale registered pixel escaped valid-only bank gate");
      invalid_guard_checks=invalid_guard_checks+1;
      if(dut.raster.pipe_packet_q!==92'd0)stale_hold_samples=stale_hold_samples+1;
    end
  end
  integer i,n,saved_drops;
  initial begin
    if(MODE<0 || MODE>2)$fatal(1,"P219 invalid mode");
    boot();
    // An incomplete physical source frame must be rejected before startup.
    write_word(BASE,expected(0,0));hw(6'h31,8'h01);
    repeat(12)@(negedge pixel_clk);
    if(!host_fault || !pixel_fault || pixel_ce || video_de)
      $fatal(1,"P227 incomplete source frame leaked");
    boot();
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,expected(0,i));
    hw(6'h31,8'h01);
    n=0;
    while(!dut.raster.run_q && n<50000)begin @(negedge pixel_clk);n=n+1;end
    if(!dut.raster.run_q || host_fault || pixel_fault)
      $fatal(1,"P227 first complete staged frame never became front");
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
    saved_drops=dut.raster.duplicate_frames_q;
    if(saved_drops==0)
      $fatal(1,"P227 did not demonstrate dropped duplicate epoch frames");
    // Strict front-lock survives independent pixel-domain publication.
    hw(6'h02,8'h01);
    repeat(6)@(negedge pixel_clk);
    if(!host_fault || !pixel_fault || video_de)
      $fatal(1,"P227 published front mutation not fatal/blank");
    // Sub-host-cycle raw reset pulse must STILL reset host-side synchronous
    // committed EBR source and perform both pixel-clock-local EBR scrub walks.
    @(negedge pixel_clk);
    #1 rst_n=0;
    #1 if(dut.fabric_rst_n!==0)$fatal(1,"P227 raw async reset not forwarded");
    #1 rst_n=1; // only 2 ns low, shorter than either physical clock period
    wait(dut.fabric_rst_n);
      if(!dut.host_rst_n || !dut.pixel_rst_n) $fatal(1,"P227 both reset domains must qualify");
    n=0;
    while(!dut.raster.scrub_done_q && n<WORDS+8)begin
      @(negedge pixel_clk);n=n+1;
      if(video_de || video_pixel!==48'd0)
        $fatal(1,"P227 released stale video during short pulse scrub");
    end
    if(!dut.raster.scrub_done_q)
      $fatal(1,"P227 short reset failed to complete physical scrub");
    for(i=0;i<WORDS;i=i+1)
      if(dut.raster.frame0[i]!==48'd0 || dut.raster.frame1[i]!==48'd0)
        $fatal(1,"P227 short reset left nonzero pixel EBR word=%0d",i);
    if(host_fault || pixel_fault || video_de || video_pixel!==48'd0)
      $fatal(1,"P227 source/pixel reset failed closed");
    boot();
    if(dut.raster.front_valid_q || video_pixel!==48'd0)
      $fatal(1,"P227 pixel local BRAM became visible without fresh frame");
    // P219: freeze both clocks while a real nonzero pixel is actively visible.
    // A 2 ns raw reset must blank that output without either clock edge.
    // Restart the pixel clock first: the remote host-ready condition must
    // prevent release; only then may restarting host permit a fresh scrub.
    if(WORDS==8)begin
      for(i=0;i<WORDS;i=i+1)write_word(BASE+i,expected(0,i));
      hw(6'h31,8'h01);
      n=0;
      while(!dut.raster.run_q && n<50000)begin @(negedge pixel_clk);n=n+1;end
      if(!dut.raster.run_q)$fatal(1,"P219 live-frame startup timeout");
      n=0;
      while(!video_de && n<HT*VT*DIV+100)begin
        @(negedge pixel_clk);n=n+1;
      end
      if(!video_de || video_pixel===48'd0)
        $fatal(1,"P219 never saw a nonzero live pixel");
      @(negedge host_clk);
      host_clk_running=0;
      pixel_clk_running=0;
      #(2*(HOST_HALF+PIXEL_HALF)+5);
      if(video_de!==1 || video_pixel===48'd0)
        $fatal(1,"P219 live pixel was lost before reset");
      #1 rst_n=0;
      #1;
      if(dut.host_rst_n!==0 || dut.pixel_rst_n!==0 ||
         video_de!==0 || video_pixel!==48'd0 || pixel_ce!==0)
        $fatal(1,"P219 stopped-clock asynchronous reset did not blank live pixel");
      #1 rst_n=1;
      #(2*(HOST_HALF+PIXEL_HALF)+5);
      if(dut.host_rst_n!==0 || dut.pixel_rst_n!==0 ||
         dut.fabric_rst_n!==0 || video_de!==0 || video_pixel!==48'd0)
        $fatal(1,"P219 stopped-clock reset spuriously released");
      pixel_clk_running=1;
      repeat(8)@(posedge pixel_clk);
      if(dut.pixel_rst_n!==0 || dut.fabric_rst_n!==0 ||
         video_de!==0 || video_pixel!==48'd0)
        $fatal(1,"P219 pixel-only restart ignored stopped host clock");
      host_clk_running=1;
      wait(dut.fabric_rst_n);
      n=0;
      while(!dut.raster.scrub_done_q && n<WORDS+40)begin
        @(negedge pixel_clk);n=n+1;
        if(video_de || video_pixel!==48'd0)
          $fatal(1,"P219 stale live frame leaked while scrubbing");
      end
      if(!dut.raster.scrub_done_q)
        $fatal(1,"P219 reboot did not finish both pixel EBR scrubs");
      for(i=0;i<WORDS;i=i+1)
        if(dut.raster.frame0[i]!==48'd0 || dut.raster.frame1[i]!==48'd0)
          $fatal(1,"P219 stale EBR pixel survived restart index=%0d",i);
      if(host_fault || pixel_fault || video_de ||
         video_pixel!==48'd0 || dut.raster.front_valid_q)
        $fatal(1,"P219 stale frame/fault survived stopped-clock reboot");
    end

    if(invalid_guard_checks<1)
      $fatal(1,"P227 invalid-lane guard never exercised");
    // Nonzero stale payload proves the valid gate, not a zeroed data lane,
    // prevents old packets from becoming writes or frame publications.
    if(stale_hold_samples<1)
      $fatal(1,"P227 stale-nonzero valid-lane guard never exercised");
    if(prestart_hold_checks<1)
      $fatal(1,"P227 startup counter hold was never observed");
    $display("P227_STARTUP_COUNTER_RASTER_PASS words=%0d mode=%0d host_half_ns=%0d pixel_half_ns=%0d frames=2 epochs=2 no_torn_frame=1 vblank_swap=1 short_reset=1 live_clock_stop=%0d remote_ready_hold=%0d duplicate_drops=%0d invalid_guard_checks=%0d stale_hold_samples=%0d prestart_hold_checks=%0d",
      WORDS,MODE,HOST_HALF,PIXEL_HALF,(WORDS==8),(WORDS==8),saved_drops,
      invalid_guard_checks,stale_hold_samples,prestart_hold_checks);
    $finish;
  end
  initial begin #800000000;$fatal(1,"P219 bounded skewed raster timeout");end
endmodule
