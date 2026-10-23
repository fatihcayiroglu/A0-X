`timescale 1ns/1ps
module a0_p133_dual_clock_bridge_tb;
  reg host_clk=0, gpu_clk=0;
  always #3 host_clk=~host_clk;
  always #11 gpu_clk=~gpu_clk;
  reg rst_n=0;
  reg h_req_valid=0,h_req_write=0,h_rsp_ready=0;
  reg [7:0] h_req_addr=0;
  reg [31:0] h_req_wdata=0;
  wire h_req_ready,h_rsp_valid,h_rsp_error;
  wire [31:0] h_rsp_rdata;
  integer i;
  reg [31:0] result;
  reg completed;
  reg saw_request_full=0, saw_response_full=0;
  always @(posedge host_clk) begin
    if(rst_n && dut.hrst_n && dut.request_fifo.wfull)
      saw_request_full <= 1;
  end
  always @(posedge gpu_clk) begin
    if(rst_n && dut.grst_n && dut.response_fifo.wfull)
      saw_response_full <= 1;
  end

  a0_p133_dual_clock_bridge #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(
    .host_clk(host_clk),.gpu_clk(gpu_clk),.rst_n(rst_n),
    .h_req_valid(h_req_valid),.h_req_ready(h_req_ready),
    .h_req_write(h_req_write),.h_req_addr(h_req_addr),
    .h_req_wdata(h_req_wdata),.h_rsp_valid(h_rsp_valid),
    .h_rsp_ready(h_rsp_ready),.h_rsp_rdata(h_rsp_rdata),
    .h_rsp_error(h_rsp_error)
  );

  task automatic post(input reg wr,input reg [7:0] addr,input reg [31:0] data);
    integer cycles;
    begin
      @(negedge host_clk);
      h_req_valid=1;h_req_write=wr;h_req_addr=addr;h_req_wdata=data;
      cycles=0;
      while(h_req_ready !== 1'b1) begin
        @(negedge host_clk);
        cycles=cycles+1;
        if(cycles>500) $fatal(1,"P133 host request stalled forever at %h",addr);
      end
      @(posedge host_clk);
      @(negedge host_clk);
      h_req_valid=0;
    end
  endtask

  task automatic collect(input reg expected_error,output reg [31:0] data);
    integer cycles;
    reg [31:0] snapshot;
    reg err_snapshot;
    begin
      cycles=0;
      while(h_rsp_valid !== 1'b1) begin
        @(negedge host_clk);
        cycles=cycles+1;
        if(cycles>3000) $fatal(1,"P133 host response timed out");
      end
      snapshot=h_rsp_rdata;err_snapshot=h_rsp_error;
      if(err_snapshot !== expected_error)
        $fatal(1,"P133 wrong error result: %b vs %b",err_snapshot,expected_error);
      repeat(4) begin
        @(posedge host_clk);
        @(negedge host_clk);
        if(!h_rsp_valid || h_rsp_rdata !== snapshot ||
           h_rsp_error !== err_snapshot)
          $fatal(1,"P133 response changed during backpressure");
      end
      data=snapshot;
      h_rsp_ready=1;
      @(posedge host_clk);
      @(negedge host_clk);
      h_rsp_ready=0;
    end
  endtask

  task automatic access(input reg wr,input reg [7:0] addr,input reg [31:0] value,
                        input reg expect_err,output reg [31:0] got);
    begin
      post(wr,addr,value);
      collect(expect_err,got);
    end
  endtask

  // Deliberately stop the host response consumer long enough to fill the
  // response FIFO, block P132, and eventually fill the request FIFO too.
  // Every read response has a unique expected index; zeros are write acks.
  task automatic overflowing_producer;
    integer k;
    begin
      for(k=0;k<24;k=k+1) begin
        post(1,8'h0c,32'h00010000+k);
        post(0,8'h0c,0);
      end
    end
  endtask
  task automatic delayed_collector;
    integer k;
    reg [31:0] value;
    begin
      repeat(250) @(negedge host_clk);
      for(k=0;k<24;k=k+1) begin
        collect(0,value);
        if(value !== 0) $fatal(1,"P133 burst write acknowledgement mismatch %h",value);
        collect(0,value);
        if(value !== (32'h00010000+k))
          $fatal(1,"P133 burst read duplicate/reorder/loss at %0d got %h",k,value);
      end
    end
  endtask

  initial begin
    repeat(5) @(negedge gpu_clk);
    rst_n=1;
    repeat(5) @(negedge host_clk);
    access(0,8'h00,0,0,result);
    if(result !== 32'h41305832) $fatal(1,"P133 initial ID mismatch %h",result);
    // Burst faster than GPU clock; preserve exact response order.
    post(1,8'h0c,32'h00123456);
    post(1,8'h10,32'h00ffffff);
    post(1,8'h14,32'h00000000);
    post(1,8'h18,32'h00000003);
    for(i=0;i<4;i=i+1) begin
      collect(0,result);
      if(result !== 0) $fatal(1,"P133 write response payload mismatch");
    end
    access(0,8'h0c,0,0,result);
    if(result !== 32'h00123456) $fatal(1,"P133 staging data corrupted");
    access(1,8'h05,32'h55,1,result);
    access(0,8'h00,0,0,result);
    if(result !== 32'h41305832) $fatal(1,"P133 reordered error/ID response");
    access(1,8'h08,32'h00000004,0,result); // acknowledge error
    access(1,8'h08,32'h00000001,0,result); // clear
    completed=0;
    for(i=0;i<60 && !completed;i=i+1) begin
      access(0,8'h04,0,0,result);
      if(result[2] && result[0]) completed=1;
    end
    if(!completed) $fatal(1,"P133 clear completion not delivered");
    access(1,8'h34,0,0,result);
    access(0,8'h38,0,0,result);
    if(result !== 32'h80123456) $fatal(1,"P133 color readback wrong %h",result);
    access(0,8'h3c,0,0,result);
    if(result !== 32'h80ffffff) $fatal(1,"P133 depth readback wrong %h",result);

    fork
      overflowing_producer();
      delayed_collector();
    join
    if(!saw_request_full || !saw_response_full)
      $fatal(1,"P133 did not verify both FIFO full backpressure paths req=%b rsp=%b",
             saw_request_full,saw_response_full);

    // Explicit shared reset must invalidate a queued, backpressured response.
    post(0,8'h00,0);
    i=0;
    while(!h_rsp_valid) begin
      @(negedge host_clk);
      i=i+1;
      if(i>3000) $fatal(1,"P133 reset response timeout");
    end
    @(negedge host_clk);
    rst_n=0;
    repeat(3) @(negedge host_clk);
    if(h_rsp_valid || h_req_ready) $fatal(1,"P133 stale response after reset");
    repeat(3) @(negedge gpu_clk);
    rst_n=1;
    repeat(5) @(negedge gpu_clk);
    access(0,8'h00,0,0,result);
    if(result !== 32'h41305832) $fatal(1,"P133 failed after reset");
    $display("P133_REAL_DUAL_CLOCK_RTL_PASS ordered burst/backpressure/clear/readback/reset");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1,"P133 global two-clock watchdog");
  end
endmodule
