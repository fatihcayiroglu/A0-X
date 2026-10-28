`timescale 1ns/1ps
// P210 abstract frame-stream handshakes: verify a queued publish cannot
// interrupt a frame, including while last pixel is indefinitely stalled.
module a0_p210_frame_boundary_stream_tb #(
  parameter integer WORDS=8
);
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0,pixel_ready=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,fault,busy,pixel_valid,frame_start,frame_end;
  wire [7:0] host_rdata;
  wire [47:0] pixel_data;
  wire [9:0] pixel_index;
  wire [31:0] pixel_epoch;
  localparam logic [31:0] BASE=32'h01000000;
  logic writer_published=0;
  a0_p210_frame_boundary_stream #(
    .WORDS(WORDS),.RESPONSE_TIMEOUT(256)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(fault),.busy(busy),
    .pixel_ready(pixel_ready),.pixel_valid(pixel_valid),
    .pixel_data(pixel_data),.pixel_index(pixel_index),
    .pixel_epoch(pixel_epoch),
    .frame_start(frame_start),.frame_end(frame_end)
  );
  function automatic [47:0] pixel(input integer bank,input integer addr);
    pixel={bank ? 16'hb19a : 16'h3e5f,16'(addr),16'(addr ^ 16'ha53c)};
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] data);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=data;
      #1;if(!host_ready)$fatal(1,"P210 host write not ready a=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] data);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P210 host read not ready a=%h",a);
      data=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic boot;
    integer cycles;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;
      pixel_ready=0;writer_published=0;
      repeat(3)@(negedge clk);rst_n=1;
      cycles=0;
      while(busy && cycles<WORDS+180)begin
        @(negedge clk);cycles=cycles+1;
      end
      if(busy || fault || pixel_valid || cycles<WORDS)
        $fatal(1,"P210 reset/scrub premature pixel cycles=%0d",cycles);
    end
  endtask
  task automatic prepare_write(input logic [31:0] addr,
                               input logic [47:0] word);
    integer j;
    begin
      hw(6'h02,8'h01);
      for(j=0;j<4;j=j+1)hw(6'h04+6'(j),addr[j*8+:8]);
      for(j=0;j<6;j=j+1)hw(6'h08+6'(j),word[j*8+:8]);
    end
  endtask
  task automatic write_word(input logic [31:0] addr,
                            input logic [47:0] word);
    logic [7:0] st;
    integer n;
    begin
      prepare_write(addr,word);hw(6'h00,8'h01);
      st=0;n=0;
      while(!st[3] && n<180)begin
        hr(6'h01,st);n=n+1;
        if(st[4] || fault)$fatal(1,"P210 write fault");
      end
      if(!st[3] || n<3)$fatal(1,"P210 write COMMIT not reached");
      hr(6'h16,st);
      if(st[0])$fatal(1,"P210 backend write error");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic select_bank(input logic bank);
    logic [7:0] st;
    begin
      hw(6'h30,{7'd0,bank});
      hr(6'h33,st);
      if(st[0]!==bank)$fatal(1,"P210 bank select not mirrored");
    end
  endtask
  task automatic wait_pixel(input integer idx,input integer epoch,
                            input logic [47:0] expected);
    integer n;
    begin
      n=0;
      @(negedge clk);
      while(!pixel_valid && n<35000)begin @(negedge clk);n=n+1;end
      if(!pixel_valid || fault || pixel_index!==10'(idx) ||
         pixel_epoch!==32'(epoch) || pixel_data!==expected ||
         frame_start!==(idx==0) || frame_end!==(idx==WORDS-1))
        $fatal(1,"P210 wrong pixel idx=%0d got=%0d epoch=%0d exp_epoch=%0d data=%h exp=%h start=%b end=%b",
          idx,pixel_index,pixel_epoch,epoch,pixel_data,expected,frame_start,frame_end);
    end
  endtask
  task automatic consume_pixel(input integer idx,input integer epoch,
                               input logic [47:0] expected);
    begin
      wait_pixel(idx,epoch,expected);
      pixel_ready=1;
      @(negedge clk);pixel_ready=0;
    end
  endtask
  integer i;
  initial begin
    boot();
    // A single repeated word never constitutes an entire publishable frame.
    write_word(BASE,pixel(0,0));
    write_word(BASE,pixel(0,0));
    hw(6'h31,8'h01);
    repeat(12)@(negedge clk);
    if(!fault || pixel_valid)
      $fatal(1,"P210 incomplete frame illegally published");
    boot();
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,pixel(0,i));
    hw(6'h31,8'h01); // initial publication may proceed without prior front
    // While frame 0 is being consumed, producer writes complete frame 1.
    fork
      begin : producer
        integer n;
        select_bank(1);
        for(n=0;n<WORDS;n=n+1)
          write_word(BASE+WORDS+n,pixel(1,n));
        hw(6'h31,8'h01); // queued until final pixel actually consumed
        writer_published=1;
      end
      begin : consumer
        integer n,timeout_cycles;
        for(n=0;n<WORDS-1;n=n+1)
          consume_pixel(n,1,pixel(0,n));
        wait_pixel(WORDS-1,1,pixel(0,WORDS-1));
        // Hold the final old-frame word regardless of how soon frame1
        // completes; publication must remain queued while stalled.
        timeout_cycles=0;
        while(!writer_published && timeout_cycles<100000)begin
          @(negedge clk);timeout_cycles=timeout_cycles+1;
        end
        if(!writer_published || !dut.publish_queued_q ||
           !pixel_valid || pixel_epoch!==1 || pixel_index!==10'(WORDS-1))
          $fatal(1,"P210 switched/expired old front before last-pixel ACK");
        repeat(5)begin
          @(negedge clk);
          if(pixel_epoch!==1 || pixel_data!==pixel(0,WORDS-1) ||
             !pixel_valid || !frame_end)
            $fatal(1,"P210 stalled final pixel mutated by queued publication");
        end
        pixel_ready=1;
        @(negedge clk);pixel_ready=0;
      end
    join
    // Only after the exact final-pixel handshake can epoch 2 begin.
    for(i=0;i<WORDS;i=i+1)
      consume_pixel(i,2,pixel(1,i));
    // Host still cannot mutate the published front.
    hw(6'h02,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || pixel_valid)
      $fatal(1,"P210 missed published-front mutation");
    boot();
    if(pixel_valid || dut.scanout.shadow0[0]!==48'd0 ||
       dut.scanout.shadow1[0]!==48'd0)
      $fatal(1,"P210 stale frame leaked after reset scrub");
    $display("P210_FRAME_BOUNDARY_PASS words=%0d full_frames=2 epochs=2 last_pixel_fence=1 stalled_pixel_stable=1 parallel_back_write=1 invalid_publish=1 reset_scrub=1",WORDS);
    $finish;
  end
  initial begin #35000000;$fatal(1,"P210 bounded simulation timeout");end
endmodule
