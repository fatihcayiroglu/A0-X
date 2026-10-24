`timescale 1ns/1ps
// P138 golden array reference: each accepted operation is checked against a
// wholly independent indexed-memory software oracle on the accepting edge.
// Both physical banks may be addressed concurrently; same bank has lane0
// priority and requires lane1 to hold its request for retry.
module a0_p138_dual_bank_framebuffer_tb #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
  parameter integer ADDR_BITS=PIXELS<=1?1:$clog2(PIXELS)
);
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0;
  reg req0_valid=0,req0_write=0;
  reg req1_valid=0,req1_write=0;
  reg [ADDR_BITS-1:0] req0_index=0,req1_index=0;
  reg [47:0] req0_wdata=0,req1_wdata=0;
  wire req0_ready,req1_ready;
  wire rsp0_valid,rsp0_error,rsp1_valid,rsp1_error;
  wire [47:0] rsp0_rdata,rsp1_rdata;

  a0_p138_dual_bank_framebuffer #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut (
    .clk(clk),.rst_n(rst_n),
    .req0_valid(req0_valid),.req0_ready(req0_ready),
    .req0_write(req0_write),.req0_index(req0_index),.req0_wdata(req0_wdata),
    .rsp0_valid(rsp0_valid),.rsp0_error(rsp0_error),.rsp0_rdata(rsp0_rdata),
    .req1_valid(req1_valid),.req1_ready(req1_ready),
    .req1_write(req1_write),.req1_index(req1_index),.req1_wdata(req1_wdata),
    .rsp1_valid(rsp1_valid),.rsp1_error(rsp1_error),.rsp1_rdata(rsp1_rdata)
  );

  reg [47:0] golden[0:PIXELS-1];
  reg golden_valid[0:PIXELS-1];
  reg expected0_valid,expected1_valid,expected0_error,expected1_error;
  reg [47:0] expected0_data,expected1_data;
  integer checks=0,accepted=0,dual=0,conflicts=0,read_count=0;
  integer write_count=0,invalid_count=0,reset_count=0;

  always @(posedge clk) begin
    if(!rst_n) begin
      expected0_valid=0;expected1_valid=0;
      expected0_error=0;expected1_error=0;
      expected0_data=0;expected1_data=0;
      for(integer j=0;j<PIXELS;j=j+1) golden_valid[j]=0;
      reset_count=reset_count+1;
    end else begin
      expected0_valid=req0_valid && req0_ready;
      expected1_valid=req1_valid && req1_ready;
      expected0_error=expected0_valid && (int'(req0_index)>=PIXELS);
      expected1_error=expected1_valid && (int'(req1_index)>=PIXELS);
      expected0_data=0;expected1_data=0;
      if(expected0_valid && !expected0_error && !req0_write)
        expected0_data=golden_valid[req0_index] ? golden[req0_index] : 48'd0;
      if(expected1_valid && !expected1_error && !req1_write)
        expected1_data=golden_valid[req1_index] ? golden[req1_index] : 48'd0;

      if(req0_valid && req1_valid && int'(req0_index)<PIXELS &&
         int'(req1_index)<PIXELS && req0_index[0]==req1_index[0]) begin
        conflicts=conflicts+1;
        if(req1_ready !== 1'b0)
          $fatal(1,"P138 same bank was incorrectly dual-issued");
      end
      if(expected0_valid && expected1_valid) dual=dual+1;
      if(expected0_valid) begin
        accepted=accepted+1;
        if(expected0_error) invalid_count=invalid_count+1;
        else if(req0_write) begin
          golden[req0_index]=req0_wdata;
          golden_valid[req0_index]=1;
          write_count=write_count+1;
        end else read_count=read_count+1;
      end
      if(expected1_valid) begin
        accepted=accepted+1;
        if(expected1_error) invalid_count=invalid_count+1;
        else if(req1_write) begin
          golden[req1_index]=req1_wdata;
          golden_valid[req1_index]=1;
          write_count=write_count+1;
        end else read_count=read_count+1;
      end
    end
    #1;
    if({rsp0_valid,rsp0_error,rsp0_rdata,rsp1_valid,rsp1_error,rsp1_rdata} !==
       {expected0_valid,expected0_error,expected0_data,
        expected1_valid,expected1_error,expected1_data})
      $fatal(1,"P138 golden mismatch cycle=%0d index0=%0d index1=%0d actual=%b%b:%h %b%b:%h expected=%b%b:%h %b%b:%h",
        checks,req0_index,req1_index,
        rsp0_valid,rsp0_error,rsp0_rdata,rsp1_valid,rsp1_error,rsp1_rdata,
        expected0_valid,expected0_error,expected0_data,
        expected1_valid,expected1_error,expected1_data);
    checks=checks+1;
  end

  task automatic step(
    input reg v0,w0,
    input integer idx0,
    input reg [47:0] data0,
    input reg v1,w1,
    input integer idx1,
    input reg [47:0] data1
  );
    begin
      @(negedge clk);
      req0_valid=v0;req0_write=w0;req0_index=ADDR_BITS'(idx0);req0_wdata=data0;
      req1_valid=v1;req1_write=w1;req1_index=ADDR_BITS'(idx1);req1_wdata=data1;
      @(posedge clk);
      #2;
    end
  endtask

  function automatic [47:0] payload(input integer k, input integer salt);
    reg [47:0] val;
    begin
      val=48'(64'hd2e0b53f92ac ^ (64'(k)*64'h102030405) ^ (64'(salt)<<24));
      payload=val;
    end
  endfunction

  task automatic scan_all(input reg should_be_zero);
    begin
      for(integer i=0;i<PIXELS;i=i+2) begin
        step(1,0,i,48'd0,(i+1<PIXELS),0,i+1,48'd0);
        if(should_be_zero && (rsp0_rdata!=0 || (i+1<PIXELS && rsp1_rdata!=0)))
          $fatal(1,"P138 new or reset storage leaked dirty memory at index=%0d",i);
      end
    end
  endtask

  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    scan_all(1);
    // Both banks write in same clock, for every valid location.
    for(integer i=0;i<PIXELS;i=i+2)
      step(1,1,i,payload(i,1),(i+1<PIXELS),1,i+1,payload(i+1,2));
    scan_all(0);

    // Sustained heterogeneous dual-bank traffic, both bank assignments.
    for(integer i=0;i<512;i=i+1) begin
      step(1,(i%3)!=0,2*(i%((PIXELS+1)/2)),payload(i,3),
           1,(i%4)!=0,2*(i%(PIXELS/2))+1,payload(i,4));
    end
    // Bank contention: request1 must be rejected, not executed twice.
    step(1,1,0,payload(0,5),1,1,2,payload(2,6));
    if(req1_ready !== 0 || rsp1_valid !== 0)
      $fatal(1,"P138 request1 wrongly acknowledged a bank conflict");
    step(0,0,0,0,1,1,2,payload(2,6));
    step(1,0,0,0,1,0,2,0);
    if(rsp1_valid || req1_ready)
      $fatal(1,"P138 same-bank dual read must stall lane 1");
    step(0,0,0,0,1,0,2,0);
    // Extended lane1-stall/retry stress: every same-bank operation must
    // be rejected and retried exactly once, across read/write variations.
    for(integer k=0;k<128;k=k+1) begin
      step(1,(k%3)!=0,2*(k%((PIXELS+1)/2)),payload(k,9),
           1,(k%4)!=0,2*((k+1)%((PIXELS+1)/2)),payload(k,10));
      if(req1_ready || rsp1_valid)
        $fatal(1,"P138 lane1 accepted same-bank collision at iteration %0d",k);
      step(0,0,0,0,
           1,(k%4)!=0,2*((k+1)%((PIXELS+1)/2)),payload(k,10));
      if(!req1_ready || !rsp1_valid)
        $fatal(1,"P138 deferred lane1 retry was not accepted at iteration %0d",k);
    end
    scan_all(0);

    // Invalid addresses are acknowledged with errors rather than hanging.
    // An invalid lane0 must not consume a physical bank or block lane1.
    if((1<<ADDR_BITS)>PIXELS) begin
      step(1,1,PIXELS,48'hbadbadbadbad,1,0,1,0);
      if(!rsp0_error || rsp1_error || !rsp1_valid)
        $fatal(1,"P138 invalid-index isolation failed");
      step(1,0,PIXELS,0,1,1,PIXELS+1,48'hfa11fa11fa11);
      if(!rsp0_error || !rsp1_error)
        $fatal(1,"P138 dual invalid requests must both report errors");
    end

    // Reset must flush responses and invalidate all values without using
    // a huge synchronous framebuffer clearing loop or leaving stale reads.
    @(negedge clk);
    rst_n=0;req0_valid=0;req1_valid=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    scan_all(1);
    for(integer i=0;i<PIXELS;i=i+2)
      step(1,1,i,payload(i,7),(i+1<PIXELS),1,i+1,payload(i+1,8));
    scan_all(0);
    step(0,0,0,0,0,0,0,0);
    if(rsp0_valid || rsp1_valid)
      $fatal(1,"P138 idle response pulse not flushed");
    if(checks<500 || accepted<1000 || dual<500 || conflicts<130 ||
       read_count<100 || write_count<250 || reset_count<4)
      $fatal(1,"P138 insufficient exercised paths checks=%0d accepted=%0d dual=%0d conflict=%0d read=%0d write=%0d resets=%0d",
         checks,accepted,dual,conflicts,read_count,write_count,reset_count);
    if((1<<ADDR_BITS)>PIXELS && invalid_count<2)
      $fatal(1,"P138 insufficient invalid-index tests");
    $display("P138_DUAL_BANK_GOLDEN_PASS pixels=%0d checks=%0d accepted=%0d dual=%0d conflicts=%0d reads=%0d writes=%0d invalid=%0d",
       PIXELS,checks,accepted,dual,conflicts,read_count,write_count,invalid_count);
    $finish;
  end
  initial begin
    #3000000;
    $fatal(1,"P138 real RTL golden watchdog");
  end
endmodule
