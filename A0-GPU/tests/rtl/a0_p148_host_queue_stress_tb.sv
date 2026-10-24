`timescale 1ns/1ps
// P148 real FIFO protocol stress over the P147 register, raster and BRAM.
// Host stops accepting responses. Queue must fill and stall exactly,
// replies remain stable, then all ordered success/error replies drain.
// No mock core, no ignored/skipped cases.
module a0_p148_host_queue_stress_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
  reg [4:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;

  a0_p148_ordered_host_queue_top #(
    .FRAME_WIDTH(4),.FRAME_HEIGHT(4)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_ready(req_ready),
    .req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );

  reg [32:0] expected [0:2047]; // {error, exact 32-bit reply}
  integer sent=0,received=0,full_stalls=0,held_cycles=0;
  integer rejected=0,accepted=0,reset_flushes=0;
  integer cycle=0,after_reset_reads=0;
  reg auto_stall=0;
  always @(negedge clk)begin
    cycle=cycle+1;
    if(auto_stall)rsp_ready=(cycle%9>=4);
  end
  always @(posedge clk)begin
    if(rst_n && rsp_valid && rsp_ready)begin
      if(received>=sent)
        $fatal(1,"P148 phantom response: received=%0d sent=%0d",received,sent);
      if({rsp_error,rsp_rdata}!==expected[received])
        $fatal(1,"P148 out-of-order/corrupt response #%0d expected=%h got=%h",
           received,expected[received],{rsp_error,rsp_rdata});
      if(rsp_error)rejected=rejected+1;
      else accepted=accepted+1;
      received=received+1;
    end
  end

  task automatic enqueue(
    input reg write_access,input reg [4:0] addr,
    input reg [31:0] value,
    input reg expected_error,input reg [31:0] expected_data
  );
    integer watchdog;
    begin
      @(negedge clk);
      watchdog=0;
      while(!req_ready)begin
        @(negedge clk);
        watchdog=watchdog+1;
        if(watchdog>9000)
          $fatal(1,"P148 input never became ready for addr=%0d",addr);
      end
      expected[sent]={expected_error,expected_data};
      sent=sent+1;
      req_write=write_access;req_addr=addr;
      req_wdata=value;req_valid=1;
      @(posedge clk);
      @(negedge clk);req_valid=0;
    end
  endtask

  task automatic drain(input integer target);
    integer watchdog;
    begin
      watchdog=0;
      while(received<target)begin
        @(negedge clk);
        watchdog=watchdog+1;
        if(watchdog>9000)
          $fatal(1,"P148 drain timed out received=%0d target=%0d",received,target);
      end
    end
  endtask
  task automatic wait_response;
    integer watchdog;
    begin
      watchdog=0;
      while(!rsp_valid)begin
        @(negedge clk);
        watchdog=watchdog+1;
        if(watchdog>500)$fatal(1,"P148 response did not arrive");
      end
    end
  endtask

  initial begin
    repeat(4)@(negedge clk);
    rst_n=1;
    // Response0 intentionally remains unacknowledged. Backend MUST stop
    // progressing after response0, despite following accepted requests.
    enqueue(1,5'd2,32'h00112233,0,0);
    wait_response();
    if(rsp_error || rsp_rdata!==0 || !rsp_valid)
      $fatal(1,"P148 initial write response corrupted");
    enqueue(1,5'd2,32'h00112244,0,0);
    enqueue(1,5'd2,32'h00112255,0,0);
    enqueue(1,5'd12,32'd1,1,0); // STATUS is read-only
    enqueue(0,5'd2,0,0,32'h00112255);
    if(req_ready!==0 || dut.used_q!==4)
      $fatal(1,"P148 did not fill four-slot FIFO exactly");
    // While full, maliciously hold an additional valid request. No
    // acceptance is allowed and the original reply must remain stable.
    @(negedge clk);
    req_valid=1;req_write=1;req_addr=2;req_wdata=32'hbeefbeef;
    repeat(12)begin
      @(negedge clk);
      if(req_ready!==0 || !rsp_valid || rsp_error || rsp_rdata!==0)
        $fatal(1,"P148 backpressure corrupted full queue/response");
      full_stalls=full_stalls+1;
      held_cycles=held_cycles+1;
    end
    req_valid=0;
    rsp_ready=1;
    drain(5);
    // Invalid STATUS write must create exactly one failed response and
    // must not prevent subsequent read of the prior valid RGB register.
    if(rejected!=1 || received!=5 || dut.used_q!=0)
      $fatal(1,"P148 did not drain ordered success/error sequence");

    // Stress hundreds of writes/readbacks with deterministic host stalls.
    auto_stall=1;
    for(integer k=0;k<120;k=k+1)begin
      enqueue(1,5'd2,32'(k+16'h2100),0,0);
      enqueue(0,5'd2,0,0,32'(k+16'h2100));
      enqueue(0,5'd31,0,1,0);
    end
    drain(365);
    auto_stall=0;
    @(negedge clk);rsp_ready=1;
    if(received!=sent || rejected<121 || accepted<244)
      $fatal(1,"P148 burst lost or duplicated responses");

    // Cancel *both* an outstanding host response and four queued
    // unissued requests. Reset may not replay a previously accepted
    // write or disclose a stale response in the new reset epoch.
    rsp_ready=0;
    enqueue(0,5'd15,0,0,32'hA0147001);
    wait_response();
    enqueue(1,5'd2,32'hff121212,0,0);
    enqueue(1,5'd2,32'hff343434,0,0);
    enqueue(0,5'd2,0,0,32'h00343434);
    enqueue(0,5'd15,0,0,32'hA0147001);
    if(req_ready || dut.used_q!==4 || !rsp_valid)
      $fatal(1,"P148 reset scenario lacks outstanding backlog");
    @(negedge clk);
    rst_n=0;req_valid=0;
    repeat(4)@(negedge clk);
    if(req_ready || rsp_valid || dut.used_q!=0 || dut.inflight_q)
      $fatal(1,"P148 reset leaked queued/inflight/response state");
    reset_flushes=reset_flushes+1;
    sent=0;received=0;
    rst_n=1;
    rsp_ready=1;
    enqueue(0,5'd2,0,0,0);
    enqueue(0,5'd15,0,0,32'hA0147001);
    drain(2);
    after_reset_reads=received;
    repeat(10)@(negedge clk);
    if(rsp_valid || received!=2 || dut.used_q!=0 ||
       reset_flushes!=1 || full_stalls<12 || held_cycles<12)
      $fatal(1,"P148 stale/extra response after reset");
    $display("P148_ORDERED_HOST_FIFO_PASS depth=4 burst_requests=365 full_stalls=%0d held_response_cycles=%0d cancelled_epoch_requests=5 post_reset_reads=%0d ordered_rejected=%0d",
      full_stalls,held_cycles,after_reset_reads,rejected);
    $finish;
  end
  initial begin #50000000;$fatal(1,"P148 queue stress watchdog");end
endmodule
