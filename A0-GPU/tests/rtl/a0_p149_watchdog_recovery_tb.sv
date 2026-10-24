`timescale 1ns/1ps
// P149 bounded watchdog fault-injection: deliberately suppresses ONLY the
// wrapper's observed backend response signal (not a mock raster or RAM).
// Validates fail-closed latched link fault, no stale reply, single-increment
// epoch on held link_reset, and fresh real P147 ID/read-only-error replies.
module a0_p149_watchdog_recovery_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,link_reset=0,req_valid=0,req_write=0,rsp_ready=1;
  reg [7:0] req_id=0;
  reg [4:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error,link_fault;
  wire [7:0] rsp_id;
  wire [15:0] rsp_epoch;
  wire [31:0] rsp_rdata;
  integer errors=0,completed=0,resets=0;

  a0_p149_epoch_tagged_host_link #(
    .FRAME_WIDTH(4),.FRAME_HEIGHT(4),.WATCHDOG_CYCLES(16)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .link_reset(link_reset),.link_fault(link_fault),
    .req_valid(req_valid),.req_write(req_write),
    .req_ready(req_ready),.req_id(req_id),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_epoch(rsp_epoch),.rsp_rdata(rsp_rdata)
  );

  task automatic issue(input reg wr,input reg [4:0] adr,
                       input reg [7:0] ident,input reg [31:0] value);
    begin
      @(negedge clk);
      if(!req_ready)$fatal(1,"P149 fresh link not ready");
      req_valid=1;req_write=wr;req_addr=adr;
      req_id=ident;req_wdata=value;
      @(posedge clk);
      @(negedge clk);req_valid=0;
    end
  endtask
  task automatic expect_reply(input reg [7:0] ident,
                              input reg bad,input reg [31:0] value);
    integer n;
    begin
      n=0;
      while(!rsp_valid)begin
        @(negedge clk);n=n+1;
        if(n>50)$fatal(1,"P149 recovered core never responded");
      end
      if(rsp_id!==ident || rsp_error!==bad || rsp_rdata!==value ||
         rsp_epoch!==16'd1 || link_fault)
        $fatal(1,"P149 recovered reply wrong id=%h err=%b data=%h epoch=%h",
               rsp_id,rsp_error,rsp_rdata,rsp_epoch);
      completed=completed+1;
      @(posedge clk);@(negedge clk);
      if(rsp_valid)$fatal(1,"P149 duplicate response after acknowledge");
    end
  endtask

  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    // The host has supplied a legitimate transaction but the observed
    // backend reply is deliberately suppressed to create a real timeout.
    force dut.core_rsp_valid=1'b0;
    issue(0,5'd15,8'h82,0);
    repeat(30)@(negedge clk);
    if(!link_fault || req_ready || rsp_valid || dut.used_q!=0)
      $fatal(1,"P149 timeout did not fail closed and flush accepted IDs");
    // The stuck backend may be released; it MUST remain quarantined
    // until a deliberate recovery event increments the generation.
    release dut.core_rsp_valid;
    repeat(4)@(negedge clk);
    if(!link_fault || rsp_valid)
      $fatal(1,"P149 fault improperly self-cleared or leaked stale response");

    link_reset=1;
    repeat(4)@(negedge clk);
    if(rsp_epoch!==16'd1 || link_fault || req_ready || rsp_valid)
      $fatal(1,"P149 held soft reset changed epoch more than once or leaked response");
    link_reset=0;
    resets=resets+1;
    issue(0,5'd15,8'h99,0);
    expect_reply(8'h99,0,32'hA0147001);
    issue(1,5'd12,8'h91,32'hdeadbeef);
    expect_reply(8'h91,1,0);
    errors=errors+1;
    issue(0,5'd2,8'h6a,0);
    expect_reply(8'h6a,0,0);
    repeat(10)@(negedge clk);
    if(link_fault || rsp_valid || dut.used_q!=0 || completed!=3 ||
       errors!=1 || resets!=1)
      $fatal(1,"P149 recovered link dropped or duplicated post-reset work");

    // Physical reset starts a NEW power-on epoch (0), distinct from
    // link reset's incrementing generation count.
    rst_n=0;
    repeat(3)@(negedge clk);
    if(rsp_epoch!==0 || req_ready || rsp_valid || link_fault)
      $fatal(1,"P149 physical reset did not return to epoch zero");
    $display("P149_WATCHDOG_RECOVERY_PASS watchdog=16 fault_injected=1 link_resets=%0d new_epoch=1 recovered_responses=%0d rejected=%0d poweron_epoch=0",resets,completed,errors);
    $finish;
  end
  initial begin #2000000;$fatal(1,"P149 watchdog test timeout");end
endmodule
