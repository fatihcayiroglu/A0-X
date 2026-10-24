`timescale 1ns/1ps
// P139 independent XY indexed-memory golden oracle, not using P138 internals.
// Tests two requests per clock in opposite interleaved banks, same-bank
// stalls/retries, OOB coords, reset and full-frame readback across shapes.
module a0_p139_xy_dual_pixel_port_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
);
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0;
  reg req0_valid=0,req1_valid=0,req0_write=0,req1_write=0;
  reg [15:0] req0_x=0,req0_y=0,req1_x=0,req1_y=0;
  reg [47:0] req0_wdata=0,req1_wdata=0;
  wire req0_ready,req1_ready,rsp0_valid,rsp1_valid,rsp0_error,rsp1_error;
  wire [47:0] rsp0_rdata,rsp1_rdata;

  a0_p139_xy_dual_pixel_port #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req0_valid(req0_valid),.req0_ready(req0_ready),
    .req0_write(req0_write),.req0_x(req0_x),.req0_y(req0_y),
    .req0_wdata(req0_wdata),.rsp0_valid(rsp0_valid),
    .rsp0_error(rsp0_error),.rsp0_rdata(rsp0_rdata),
    .req1_valid(req1_valid),.req1_ready(req1_ready),
    .req1_write(req1_write),.req1_x(req1_x),.req1_y(req1_y),
    .req1_wdata(req1_wdata),.rsp1_valid(rsp1_valid),
    .rsp1_error(rsp1_error),.rsp1_rdata(rsp1_rdata)
  );

  reg [47:0] golden[0:PIXELS-1];
  reg known[0:PIXELS-1];
  reg exp0_valid,exp1_valid,exp0_error,exp1_error;
  reg [47:0] exp0_data,exp1_data;
  integer cycles=0,accepted=0,dual=0,conflicts=0,invalid=0,reads=0,writes=0;
  integer idx0,idx1;
  reg in0,in1,expected_ready1;
  always @(posedge clk) begin
    if(!rst_n) begin
      exp0_valid=0;exp1_valid=0;exp0_error=0;exp1_error=0;
      exp0_data=0;exp1_data=0;
      for(integer i=0;i<PIXELS;i=i+1) known[i]=0;
    end else begin
      in0=(req0_x<FRAME_WIDTH && req0_y<FRAME_HEIGHT);
      in1=(req1_x<FRAME_WIDTH && req1_y<FRAME_HEIGHT);
      idx0=int'(req0_y)*FRAME_WIDTH+int'(req0_x);
      idx1=int'(req1_y)*FRAME_WIDTH+int'(req1_x);
      expected_ready1=!(req0_valid && req1_valid && in0 && in1 && ((idx0%2)==(idx1%2)));
      if(req0_ready !== 1'b1 || req1_ready !== expected_ready1)
        $fatal(1,"P139 ready arbitration mismatch x/y0=%0d,%0d x/y1=%0d,%0d",
          req0_x,req0_y,req1_x,req1_y);
      if(!expected_ready1)conflicts=conflicts+1;
      exp0_valid=req0_valid && req0_ready;
      exp1_valid=req1_valid && req1_ready;
      exp0_error=exp0_valid && !in0;
      exp1_error=exp1_valid && !in1;
      exp0_data=0;exp1_data=0;
      if(exp0_valid && !exp0_error && !req0_write)
        exp0_data=known[idx0] ? golden[idx0] : 48'd0;
      if(exp1_valid && !exp1_error && !req1_write)
        exp1_data=known[idx1] ? golden[idx1] : 48'd0;
      if(exp0_valid && exp1_valid)dual=dual+1;
      if(exp0_valid) begin
        accepted=accepted+1;
        if(exp0_error) invalid=invalid+1;
        else if(req0_write) begin
          golden[idx0]=req0_wdata;known[idx0]=1;writes=writes+1;
        end else reads=reads+1;
      end
      if(exp1_valid) begin
        accepted=accepted+1;
        if(exp1_error) invalid=invalid+1;
        else if(req1_write) begin
          golden[idx1]=req1_wdata;known[idx1]=1;writes=writes+1;
        end else reads=reads+1;
      end
    end
    #1;
    if({rsp0_valid,rsp0_error,rsp0_rdata,rsp1_valid,rsp1_error,rsp1_rdata} !==
       {exp0_valid,exp0_error,exp0_data,exp1_valid,exp1_error,exp1_data})
      $fatal(1,"P139 XY response mismatch at cycle %0d expected=%b%b:%h %b%b:%h actual=%b%b:%h %b%b:%h",
        cycles,exp0_valid,exp0_error,exp0_data,exp1_valid,exp1_error,exp1_data,
        rsp0_valid,rsp0_error,rsp0_rdata,rsp1_valid,rsp1_error,rsp1_rdata);
    cycles=cycles+1;
  end
  function automatic [47:0] data_for(input integer k,input integer salt);
    data_for=48'(64'h54c9273618aa ^ (64'(k)*64'h7d903af) ^
                 (64'(salt)*64'h100010001));
  endfunction
  task automatic step(
    input reg v0,w0,input integer x0,y0,input reg [47:0] d0,
    input reg v1,w1,input integer x1,y1,input reg [47:0] d1
  );
    begin
      @(negedge clk);
      req0_valid=v0;req0_write=w0;req0_x=16'(x0);req0_y=16'(y0);req0_wdata=d0;
      req1_valid=v1;req1_write=w1;req1_x=16'(x1);req1_y=16'(y1);req1_wdata=d1;
      @(posedge clk);#2;
    end
  endtask
  task automatic by_index(
    input reg v0,w0,input integer i0,input reg [47:0] d0,
    input reg v1,w1,input integer i1,input reg [47:0] d1
  );
    begin
      step(v0,w0,i0%FRAME_WIDTH,i0/FRAME_WIDTH,d0,
           v1,w1,i1%FRAME_WIDTH,i1/FRAME_WIDTH,d1);
    end
  endtask
  task automatic scan_all(input reg require_zero);
    begin
      for(integer i=0;i<PIXELS;i=i+2) begin
        by_index(1,0,i,0,(i+1<PIXELS),0,i+1,0);
        if(require_zero && (rsp0_rdata!==0 ||
             ((i+1<PIXELS) && rsp1_rdata!==0)))
          $fatal(1,"P139 reset data leaked at i=%0d",i);
      end
    end
  endtask
  initial begin
    repeat(4) @(negedge clk);
    rst_n=1;
    scan_all(1);
    for(integer i=0;i<PIXELS;i=i+2)
      by_index(1,1,i,data_for(i,1),(i+1<PIXELS),1,i+1,data_for(i+1,2));
    scan_all(0);
    for(integer k=0;k<512;k=k+1) begin
      // Two banks in same clock, alternating a mix of read and write.
      by_index(1,(k%3)!=0,2*(k%((PIXELS+1)/2)),data_for(k,3),
               1,(k%4)!=0,2*(k%(PIXELS/2))+1,data_for(k,4));
    end
    for(integer k=0;k<160;k=k+1) begin
      // Lane 1 must remain unconsumed until explicitly retried.
      by_index(1,(k%3)!=0,2*(k%((PIXELS+1)/2)),data_for(k,5),
               1,(k%5)!=0,2*((k+1)%((PIXELS+1)/2)),data_for(k,6));
      if(req1_ready || rsp1_valid)
        $fatal(1,"P139 conflict incorrectly accepted");
      by_index(0,0,0,0,1,(k%5)!=0,
               2*((k+1)%((PIXELS+1)/2)),data_for(k,6));
      if(!req1_ready || !rsp1_valid)
        $fatal(1,"P139 deferred coordinate request was not retried");
    end
    // Out-of-range X and Y must signal errors without reserving a bank.
    step(1,1,FRAME_WIDTH,0,48'habcdef123456,
         1,0,0,0,0);
    if(!rsp0_valid || !rsp0_error || !rsp1_valid || rsp1_error)
      $fatal(1,"P139 invalid X interfered with valid lane1");
    step(1,0,0,0,0,1,1,0,FRAME_HEIGHT,48'h1234);
    if(!rsp1_error || !rsp0_valid || rsp0_error)
      $fatal(1,"P139 invalid Y incorrectly accepted");
    step(1,0,FRAME_WIDTH,0,0,1,0,0,FRAME_HEIGHT,0);
    if(!rsp0_error || !rsp1_error || !rsp0_valid || !rsp1_valid)
      $fatal(1,"P139 two invalid coordinates not both acknowledged");
    scan_all(0);
    @(negedge clk);
    rst_n=0;req0_valid=0;req1_valid=0;
    repeat(4) @(negedge clk);
    rst_n=1;
    scan_all(1);
    for(integer i=0;i<PIXELS;i=i+2)
      by_index(1,1,i,data_for(i,7),(i+1<PIXELS),1,i+1,data_for(i+1,8));
    scan_all(0);
    step(0,0,0,0,0,0,0,0,0,0);
    if(rsp0_valid || rsp1_valid)
      $fatal(1,"P139 idle response leaked");
    if(cycles<500 || accepted<1000 || dual<500 || conflicts<160 ||
       reads<100 || writes<250 || invalid<3)
      $fatal(1,"P139 vacuous matrix: cycles=%0d ops=%0d dual=%0d collisions=%0d read=%0d write=%0d invalid=%0d",
        cycles,accepted,dual,conflicts,reads,writes,invalid);
    $display("P139_XY_DUAL_PIXEL_GOLDEN_PASS pixels=%0d cycles=%0d accepted=%0d dual=%0d conflicts=%0d reads=%0d writes=%0d invalid=%0d",
      PIXELS,cycles,accepted,dual,conflicts,reads,writes,invalid);
    $finish;
  end
  initial begin #3000000; $fatal(1,"P139 golden watchdog"); end
endmodule
