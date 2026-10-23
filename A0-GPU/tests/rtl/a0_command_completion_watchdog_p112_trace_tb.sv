`timescale 1ns/1ps
// P112 replay against ORIGINAL, unmodified P111 RTL; source of truth is the
// committed deterministic vector file. This bench must be run in an HDL sim.
module a0_command_completion_watchdog_p112_trace_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,cmd_valid=0,cmd_ready=0;
  logic [15:0] cmd_tag=0,completion_tag=0;
  logic completion_valid=0,completion_ready=0,completion_error=0;
  logic fault_sticky,pending;
  logic [15:0] active_tag,last_fault_tag;
  logic [31:0] timeout_count,tag_mismatch_count,protocol_fault_count,completed_count;
  a0_command_completion_watchdog_p111 #(.MAX_WAIT_CYCLES(7)) dut(.*);
  reg [31:0] v[0:15];
  integer fd,rc,cycle;
  string trace_path;
  initial begin
    if (!$value$plusargs("TRACE=%s",trace_path))
      $fatal(1,"P112 requires +TRACE=<absolute path to vectors>");
    fd=$fopen(trace_path,"r");
    if(fd==0)$fatal(1,"P112 cannot open trace %s",trace_path);
    for(cycle=0;cycle<4096;cycle=cycle+1) begin
      rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
        v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],
        v[8],v[9],v[10],v[11],v[12],v[13],v[14],v[15]);
      if(rc!=16)$fatal(1,"P112 truncated or malformed trace at cycle %0d rc=%0d",cycle,rc);
      @(negedge clk);
      rst_n=v[0][0];cmd_valid=v[1][0];cmd_ready=v[2][0];cmd_tag=v[3][15:0];
      completion_valid=v[4][0];completion_ready=v[5][0];
      completion_tag=v[6][15:0];completion_error=v[7][0];
      @(posedge clk); #1;
      if (fault_sticky!==v[8][0] || pending!==v[9][0] ||
          active_tag!==v[10][15:0] || last_fault_tag!==v[11][15:0] ||
          timeout_count!==v[12] || tag_mismatch_count!==v[13] ||
          protocol_fault_count!==v[14] || completed_count!==v[15]) begin
        $display("P112 RTL actual: fault=%h pending=%h active=%h last=%h timeout=%h mismatch=%h protocol=%h completed=%h",
          fault_sticky,pending,active_tag,last_fault_tag,timeout_count,
          tag_mismatch_count,protocol_fault_count,completed_count);
        $display("P112 oracle exp: fault=%h pending=%h active=%h last=%h timeout=%h mismatch=%h protocol=%h completed=%h",
          v[8],v[9],v[10],v[11],v[12],v[13],v[14],v[15]);
        $fatal(1,"P112 pin-level mismatch cycle=%0d",cycle);
      end
    end
    rc=$fscanf(fd,"%h",v[0]);
    if(rc!=-1)$fatal(1,"P112 unexpected extra rows or trailing garbage rc=%0d",rc);
    $fclose(fd);
    $display("P112_WATCHDOG_RTL_CYCLE_TRACE_PASS cycles=4096");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1,"P112 watchdog trace hung");
  end
endmodule
