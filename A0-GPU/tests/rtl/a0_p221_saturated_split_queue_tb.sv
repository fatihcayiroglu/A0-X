`timescale 1ns/1ps
// P221: deliberately saturate the P216 split-reset dual-clock FIFO while
// preserving committed physical EBR frame and epoch ordering.
module a0_p221_saturated_split_queue_tb #(
  parameter integer WORDS=8,
  parameter integer MODE=0
);
  localparam logic [31:0] BASE=32'h01000000;
  logic host_clk=0,pixel_clk=0,rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  logic pixel_ready=0,producer_done=0;
  wire host_ready,fault,busy,pixel_valid,pixel_fault,frame_start,frame_end;
  wire [7:0] host_rdata;
  wire [47:0] pixel_data;
  wire [9:0] pixel_index;
  wire [31:0] pixel_epoch;
  localparam integer HOST_HALF=(MODE==0)?4:7;
  localparam integer PIXEL_HALF=(MODE==0)?7:4;
  always #(HOST_HALF) host_clk=~host_clk;
  initial begin
    #(MODE+1);
    forever #(PIXEL_HALF) pixel_clk=~pixel_clk;
  end
  wire host_rst_n,pixel_rst_n,fabric_rst_n;
  a0_p216_split_reset_supervisor reset_guard(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.raw_rst_n(rst_n),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .both_released(fabric_rst_n)
  );
  // Physical FIFO is intentionally narrow to force true full/backpressure.
  a0_p216_split_reset_queue #(
    .WORDS(WORDS),.FIFO_ADDR_BITS(3),.RESPONSE_TIMEOUT(256)
  ) dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(fault),.busy(busy),
    .pixel_ready(pixel_ready),.pixel_valid(pixel_valid),
    .pixel_fault(pixel_fault),.pixel_data(pixel_data),
    .pixel_index(pixel_index),.pixel_epoch(pixel_epoch),
    .frame_start(frame_start),.frame_end(frame_end)
  );
  function automatic [47:0] expected(input integer bank,input integer i);
    expected={bank ? 16'hb19a : 16'h3e5f,16'(i),16'(i ^ 16'ha53c)};
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] data);
    begin
      @(negedge host_clk);host_valid=1;host_write=1;host_addr=a;host_wdata=data;
      #1;if(!host_ready)$fatal(1,"P212 host bus not ready a=%h",a);
      @(negedge host_clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] data);
    begin
      @(negedge host_clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P212 read bus not ready a=%h",a);
      data=host_rdata;
      @(negedge host_clk);host_valid=0;
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
        if(st[4] || fault)$fatal(1,"P212 write backend fault");
      end
      if(!st[3] || n<3)$fatal(1,"P212 write not COMMITed");
      hr(6'h16,st);
      if(st[0])$fatal(1,"P212 backend write error");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic boot;
    integer n;
    begin
      @(negedge host_clk);rst_n=0;host_valid=0;host_write=0;pixel_ready=0;producer_done=0;
      repeat(3)@(negedge host_clk);rst_n=1;
      wait(fabric_rst_n);
      @(negedge host_clk);
      if(!dut.source_busy)$fatal(1,"P212 source skipped physical reset scrub");
      repeat(6)@(negedge pixel_clk);
      n=0;
      while(busy && n<WORDS+180)begin @(negedge host_clk);n=n+1;end
      if(fault || pixel_fault || pixel_valid || pixel_data!==48'd0)
        $fatal(1,"P212 reset exposed stale physical frame");
    end
  endtask
  integer i,n,old_frames,second_frames,idx,epoch;
  logic [47:0] hold_pixel;
  initial begin
    if(MODE<0 || MODE>1)$fatal(1,"P221 unsupported clock mode");
    boot();
    // No complete committed front means no valid cross-clock pixels.
    write_word(BASE,expected(0,0));
    hw(6'h31,8'h01);
    repeat(10)@(negedge pixel_clk);
    if(!fault || !pixel_fault || pixel_valid || pixel_data!==48'd0)
      $fatal(1,"P212 incomplete frame escaped CDC guard");
    boot();
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,expected(0,i));
    hw(6'h31,8'h01);
    n=0;
    while(!pixel_valid && n<10000)begin @(negedge pixel_clk);n=n+1;end
    if(!pixel_valid || pixel_epoch!==1 || pixel_index!==0 || fault)
      $fatal(1,"P212 initial real FIFO front never appeared");
    hold_pixel=pixel_data;
    repeat(6)begin
      @(negedge pixel_clk);
      if(!pixel_valid || pixel_data!==hold_pixel || pixel_index!==0)
        $fatal(1,"P212 first pixel mutated under asynchronous backpressure");
    end
    // The real P210 source repeats epoch 1 continuously; refusing pixel
    // consumption must fill all eight FIFO slots despite prefetched output.
    n=0;
    while(!dut.queue.full && n<WORDS*100+5000)begin
      @(negedge host_clk);n=n+1;
    end
    if(!dut.queue.full || !pixel_valid || !busy)
      $fatal(1,"P221 failed to saturate physical dual-clock FIFO");
    repeat(24)begin
      @(negedge pixel_clk);
      if(!dut.queue.full || !pixel_valid || pixel_index!==0 ||
         pixel_epoch!==1 || pixel_data!==hold_pixel ||
         pixel_fault || fault)
        $fatal(1,"P221 full FIFO mutated first packet under long stall");
    end
    fork
      begin : back_writer
        hw(6'h30,8'h01);
        for(integer b=0;b<WORDS;b=b+1)
          write_word(BASE+WORDS+b,expected(1,b));
        hw(6'h31,8'h01);
        producer_done=1;
      end
      begin : receiver
        integer guard;
        idx=0;epoch=1;old_frames=0;second_frames=0;guard=0;
        while(second_frames<1 && guard<WORDS*800+1000)begin
          @(negedge pixel_clk);
          pixel_ready=0;
          while(!pixel_valid && guard<WORDS*800+1000)begin
            @(negedge pixel_clk);guard=guard+1;
          end
          if(!pixel_valid || pixel_fault || fault)
            $fatal(1,"P212 CDC stream missing/faulted at index=%0d",idx);
          if(pixel_epoch!==32'(epoch))begin
            if(pixel_epoch!==2 || epoch!=1 || idx!=0 || !producer_done)
              $fatal(1,"P212 mid-frame or premature epoch transition");
            epoch=2;
          end
          if(pixel_index!==10'(idx) ||
             frame_start!==(idx==0) ||
             frame_end!==(idx==WORDS-1) ||
             pixel_data!==expected(epoch-1,idx))
            $fatal(1,"P212 CDC mixed/reordered frame idx=%0d seen=%0d epoch=%0d data=%h",
              idx,pixel_index,pixel_epoch,pixel_data);
          // Consume only on the pixel clock, with periodic backpressure.
          pixel_ready=1;
          @(negedge pixel_clk);pixel_ready=0;guard=guard+1;
          if(idx==WORDS-1)begin
            idx=0;
            if(epoch==1)old_frames=old_frames+1;
            else second_frames=second_frames+1;
          end else idx=idx+1;
        end
        if(second_frames!=1 || old_frames<1)
          $fatal(1,"P212 never received both complete physical frames");
      end
    join
    // Refill the FIFO with the newer epoch; issue a raw reset while FULL.
    pixel_ready=0;
    n=0;
    while(!dut.queue.full && n<WORDS*100+5000)begin
      @(negedge host_clk);n=n+1;
    end
    if(!dut.queue.full || !pixel_valid || pixel_epoch!==2)
      $fatal(1,"P221 second epoch never refilled FIFO after drain");
    @(negedge pixel_clk);
    #1 rst_n=0;
    #1;
    if(fabric_rst_n!==0 || host_rst_n!==0 || pixel_rst_n!==0 ||
       pixel_valid!==0 || pixel_data!==48'd0)
      $fatal(1,"P221 full-FIFO 2ns raw reset did not assert");
    #1 rst_n=1;
    wait(fabric_rst_n);
    repeat(12)begin
      @(negedge pixel_clk);
      if(pixel_valid || pixel_data!==48'd0 || pixel_fault || fault)
        $fatal(1,"P221 stale full FIFO payload replayed after restart");
    end
    if(dut.queue.wbin_q!==0 || dut.queue.rbin_q!==0)
      $fatal(1,"P221 stale Gray FIFO pointers after full reset");
    boot();
    if(dut.source.scanout.shadow0[0]!==48'd0 ||
       dut.source.scanout.shadow1[0]!==48'd0)
      $fatal(1,"P221 stale EBR after full FIFO reset");
    $display("P221_SATURATED_CDC_PASS words=%0d mode=%0d fifo_depth=8 full=1 stall_pixel_edges=24 old_frames=%0d second_epoch=1 indexed=1 boundary=1 reset_full=1 stale_replay=0",
      WORDS,MODE,old_frames);
    $finish;
  end
  initial begin #800000000;$fatal(1,"P221 saturated split-domain queue timeout");end
endmodule
