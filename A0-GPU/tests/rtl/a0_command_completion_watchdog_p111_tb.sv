`timescale 1ns/1ps
module a0_command_completion_watchdog_p111_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0;
    logic cmd_valid=0,cmd_ready=0;
    logic [15:0] cmd_tag=0;
    logic completion_valid=0,completion_ready=0,completion_error=0;
    logic [15:0] completion_tag=0;
    logic fault_sticky,pending;
    logic [15:0] active_tag,last_fault_tag;
    logic [31:0] timeout_count,tag_mismatch_count,protocol_fault_count,completed_count;
    a0_command_completion_watchdog_p111 #(.MAX_WAIT_CYCLES(3)) dut(.*);

    task automatic reset_monitor;
      @(negedge clk);
      rst_n=0; cmd_valid=0;cmd_ready=0;cmd_tag=0;
      completion_valid=0;completion_ready=0;completion_tag=0;completion_error=0;
      repeat(2) @(negedge clk);
      rst_n=1;
    endtask
    task automatic step(input logic accept_command,
        input logic [15:0] atag,
        input logic offer_response,input logic ready_response,
        input logic [15:0] rtag,input logic rerr);
      @(negedge clk);
      cmd_valid=accept_command;cmd_ready=accept_command;cmd_tag=atag;
      completion_valid=offer_response;completion_ready=ready_response;
      completion_tag=rtag;completion_error=rerr;
      @(posedge clk); #1;
    endtask
    initial begin #30000; $fatal(1,"P111 watchdog hung"); end
    initial begin
      reset_monitor();
      step(1,16'd18,0,0,0,0);
      if(!pending || active_tag!==16'd18) $fatal(1,"P111 accepted tracking");
      step(0,0,0,0,0,0);
      step(0,0,1,0,16'd18,1);
      repeat(15) begin
        step(0,0,1,0,16'd18,1);
        if(fault_sticky || timeout_count) $fatal(1,"P111 response backpressure false timeout");
      end
      step(0,0,1,1,16'd18,1);
      if(completed_count!==1 || pending || fault_sticky)
        $fatal(1,"P111 valid held response failed");
      step(1,16'd19,0,0,0,0);
      step(0,0,1,1,16'd20,0);
      if(!fault_sticky || tag_mismatch_count!==1 || last_fault_tag!==20)
        $fatal(1,"P111 mismatched response not reported");
      step(0,0,1,1,16'd19,0);
      if(tag_mismatch_count!==1 || completed_count!==1)
        $fatal(1,"P111 fault must be terminal");

      reset_monitor();
      step(1,16'd33,0,0,0,0);
      step(0,0,0,0,0,0);
      step(0,0,0,0,0,0);
      if(fault_sticky) $fatal(1,"P111 early timeout");
      step(0,0,0,0,0,0);
      if(!fault_sticky || timeout_count!==1 || last_fault_tag!==33)
        $fatal(1,"P111 missing completion timeout not detected");

      reset_monitor();
      step(0,0,1,1,16'd99,0);
      if(!fault_sticky || protocol_fault_count!==1 || last_fault_tag!==99)
        $fatal(1,"P111 unsolicited completion not detected");

      reset_monitor();
      step(1,16'd88,0,0,0,0);
      step(0,0,1,0,16'd88,0);
      step(0,0,0,0,0,0);
      if(!fault_sticky || protocol_fault_count!==1)
        $fatal(1,"P111 dropped valid not detected");

      reset_monitor();
      step(1,16'd42,0,0,0,0);
      step(0,0,1,1,16'd42,1);
      if(fault_sticky || completed_count!==1) $fatal(1,"P111 error completion invalidly flagged");
      $display("P111_DIAGNOSTIC_RTL_PASS");
      $finish;
    end
endmodule
