`timescale 1ns/1ps
// P209 REAL scanout mirror EBR: concurrent read requests while producer
// commits second frame through separate primary P208/P207 EBR banks.
module a0_p209_independent_scanout_tb #(
  parameter integer WORDS=8
);
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0,scan_req_valid=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  logic [9:0] scan_word_index=0;
  wire host_ready,fault,busy,scan_req_ready,scan_rsp_valid;
  wire [7:0] host_rdata;
  wire [47:0] scan_rsp_pixel;
  wire [31:0] scan_rsp_epoch;
  localparam logic [31:0] BASE=32'h01000000;
  a0_p209_independent_scanout #(
    .WORDS(WORDS),.RESPONSE_TIMEOUT(256)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(fault),.busy(busy),
    .scan_req_valid(scan_req_valid),.scan_word_index(scan_word_index),
    .scan_req_ready(scan_req_ready),.scan_rsp_valid(scan_rsp_valid),
    .scan_rsp_pixel(scan_rsp_pixel),.scan_rsp_epoch(scan_rsp_epoch)
  );
  function automatic [47:0] pixel(input integer bank,input integer addr);
    pixel={bank ? 16'hb19a : 16'h3e5f,16'(addr),16'(addr ^ 16'ha53c)};
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] d);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=d;
      #1;if(!host_ready)$fatal(1,"P209 unexpected blocked host write %h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] d);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P209 unexpected blocked host read %h",a);
      d=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic wait_boot;
    integer ticks;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;scan_req_valid=0;
      repeat(3)@(negedge clk);rst_n=1;
      ticks=0;
      while(busy && ticks<WORDS+150)begin @(negedge clk);ticks=ticks+1;end
      if(busy || fault || ticks<WORDS || scan_req_ready)
        $fatal(1,"P209 scrub/boot barrier broken ticks=%0d",ticks);
    end
  endtask
  task automatic prepare(input logic op,input logic [31:0] addr,
                         input logic [47:0] data);
    integer j;
    begin
      hw(6'h02,{7'd0,op});
      for(j=0;j<4;j=j+1)hw(6'h04+6'(j),addr[j*8+:8]);
      if(op)for(j=0;j<6;j=j+1)hw(6'h08+6'(j),data[j*8+:8]);
    end
  endtask
  task automatic write_word(input logic [31:0] addr,input logic [47:0] data);
    logic [7:0] status;
    integer n;
    begin
      prepare(1,addr,data);
      hw(6'h00,8'h01);
      status=0;n=0;
      while(!status[3] && n<180)begin
        hr(6'h01,status);n=n+1;
        if(status[4] || fault)$fatal(1,"P209 committed write fault");
      end
      if(!status[3] || n<3)$fatal(1,"P209 missing or premature DONE");
      hr(6'h16,status);
      if(status[0])$fatal(1,"P209 write error");
      hw(6'h00,8'h02);
      if(fault)$fatal(1,"P209 acknowledged write poisoned mirror");
    end
  endtask
  task automatic select_bank(input logic bank);
    logic [7:0] st;
    begin
      hw(6'h30,{7'd0,bank});
      hr(6'h33,st);
      if(st[0]!==bank || fault)$fatal(1,"P209 producer bank select failed");
    end
  endtask
  task automatic publish_bank(input logic bank,input integer expected_epoch);
    logic [7:0] st;
    begin
      hw(6'h31,8'h01);
      repeat(3)@(negedge clk);
      hr(6'h32,st);
      if(!st[0] || st[1]!==bank || fault ||
         dut.epoch_q!==32'(expected_epoch) || !scan_req_ready)
        $fatal(1,"P209 publication failed status=%h epoch=%0d",st,dut.epoch_q);
    end
  endtask
  task automatic scan_once(input logic [9:0] idx,
                           input logic [47:0] wanted,
                           input logic [31:0] epoch);
    begin
      @(negedge clk);scan_word_index=idx;scan_req_valid=1;
      #1;if(!scan_req_ready)$fatal(1,"P209 scan req rejected idx=%0d",idx);
      @(negedge clk);scan_req_valid=0;
      if(!scan_rsp_valid || scan_rsp_pixel!==wanted ||
         scan_rsp_epoch!==epoch)
        $fatal(1,"P209 scan mismatch index=%0d pixel=%h expected=%h got_epoch=%d wanted=%d",idx,scan_rsp_pixel,wanted,scan_rsp_epoch,epoch);
    end
  endtask
  integer i,k;
  initial begin
    wait_boot();
    // Scan is *not* enabled before a complete frame is published.
    if(scan_req_ready)$fatal(1,"P209 scanout exposed unpublished/reset data");
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,pixel(0,i));
    publish_bank(0,1);
    scan_once(10'd0,pixel(0,0),32'd1);
    scan_once(10'(WORDS-1),pixel(0,WORDS-1),32'd1);
    select_bank(1);
    // Concurrent independent front reads while the producer writes
    // the second bank via the full P208/P203 committed byte protocol.
    fork
      begin : writer
        integer n;
        for(n=0;n<WORDS;n=n+1)
          write_word(BASE+WORDS+n,pixel(1,n));
      end
      begin : reader
        integer n;
        for(n=0;n<40;n=n+1)begin
          scan_once(10'd0,pixel(0,0),32'd1);
          scan_once(10'(WORDS-1),pixel(0,WORDS-1),32'd1);
        end
      end
    join
    publish_bank(1,2);
    scan_once(10'd0,pixel(1,0),32'd2);
    scan_once(10'(WORDS-1),pixel(1,WORDS-1),32'd2);
    if(WORDS<1024)begin
      @(negedge clk);scan_req_valid=1;scan_word_index=10'(WORDS);
      #1;if(scan_req_ready)$fatal(1,"P209 out-of-range scan address accepted");
      @(negedge clk);scan_req_valid=0;
    end
    // Published front remains write-locked by the unchanged P208.
    hw(6'h02,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || scan_req_ready || dut.front_bank_q!==1)
      $fatal(1,"P209 failed published-front write quarantine");
    wait_boot();
    if(dut.shadow0[0]!==48'd0 || dut.shadow1[0]!==48'd0 ||
       dut.shadow0[WORDS-1]!==48'd0 ||
       dut.shadow1[WORDS-1]!==48'd0 || scan_req_ready)
      $fatal(1,"P209 shadow EBR not reset-scrubbed");
    $display("P209_INDEPENDENT_SCANOUT_PASS words=%0d primary_banks=2 shadow_banks=2 commit_mirror=1 parallel_scan=1 epochs=2 reset_scrub=1 front_lock=1",WORDS);
    $finish;
  end
  initial begin #25000000;$fatal(1,"P209 bounded timeout");end
endmodule
