`timescale 1ns/1ps
// P170: a full 16-instruction RAW-dependent ALU program retires without
// extra fetch/decode bubbles. All four lanes have independent scalar oracle.
module a0_p170_prefetched_shader_latency_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,reg_write_valid=0,insn_write_valid=0;
  reg texture_write_valid=0,start=0;
  reg [2:0] reg_write_index=0,reg_read_index=0;
  reg [31:0] reg_write_data=0,texture_write_rgba=0;
  reg [3:0] insn_write_index=0,texture_write_x=0,texture_write_y=0;
  reg [24:0] insn_write_data=0;
  reg [4:0] start_length=0;
  wire [31:0] reg_read_data;
  wire texture_write_ready,ready,busy,done,fault;
  wire [4:0] retired_count,texture_retired_count;

  a0_p162_textured_microprogram dut(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid(reg_write_valid),.reg_write_index(reg_write_index),
    .reg_write_data(reg_write_data),.reg_read_index(reg_read_index),
    .insn_write_valid(insn_write_valid),
    .insn_write_index(insn_write_index),
    .insn_write_data(insn_write_data),
    .texture_write_valid(texture_write_valid),
    .texture_write_ready(texture_write_ready),
    .texture_write_x(texture_write_x),.texture_write_y(texture_write_y),
    .texture_write_rgba(texture_write_rgba),
    .start(start),.start_length(start_length),
    .ready(ready),.busy(busy),.done(done),.fault(fault),
    .retired_count(retired_count),
    .texture_retired_count(texture_retired_count)
  );
  task automatic wr_reg(input integer idx,input logic [31:0] data);
    begin
      @(negedge clk);if(!ready)$fatal(1,"P170 reg config busy");
      reg_write_index=3'(idx);reg_write_data=data;reg_write_valid=1;
      @(negedge clk);reg_write_valid=0;
    end
  endtask
  task automatic wr_insn(input integer idx,input logic [24:0] data);
    begin
      @(negedge clk);if(!ready)$fatal(1,"P170 insn config busy");
      insn_write_index=4'(idx);insn_write_data=data;insn_write_valid=1;
      @(negedge clk);insn_write_valid=0;
    end
  endtask

  integer cycles=0,checks=0;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    wr_reg(1,32'h01020304);
    wr_reg(2,32'h01010101);
    // Each instruction consumes the previous instruction's output.
    // Saturating byte ADD with no overflow: expected 0x11121314.
    for(integer i=0;i<16;i=i+1)
      wr_insn(i,{1'b0,8'd0,4'hf,3'd2,3'd1,3'd1,3'd2});
    @(negedge clk);if(!ready)$fatal(1,"P170 shader launch refused");
    start_length=16;start=1;
    @(negedge clk);start=0;
    if(!busy || ready || fault)$fatal(1,"P170 program failed to start");
    cycles=0;
    while(!done && !fault)begin
      @(negedge clk);cycles=cycles+1;
      if(cycles>80)$fatal(1,"P170 shader fetch/decode latency runaway");
    end
    if(cycles!=48)
      $fatal(1,"P170 extra instruction bubble cycles=%0d expected=48",cycles);
    if(fault || !ready || busy ||
       retired_count!==5'd16 || texture_retired_count!==0)
      $fatal(1,"P170 program retired incorrectly");
    reg_read_index=1;#1;
    if(reg_read_data!==32'h11121314)
      $fatal(1,"P170 dependent ALU result wrong expected=11121314 actual=%h",reg_read_data);
    checks=checks+1;
    repeat(3)begin
      @(negedge clk);
      if(done || fault || !ready || busy || retired_count!==5'd16)
        $fatal(1,"P170 post-completion contract violated");
      reg_read_index=1;#1;
      if(reg_read_data!==32'h11121314)
        $fatal(1,"P170 result changed after retirement");
      checks=checks+1;
    end
    if(checks!=4)$fatal(1,"P170 vacuous latency test");
    $display("P170_PREFETCHED_SHADER_LATENCY_PASS instructions=16 cycles=48 dependent_register_checks=%0d result=%h",
      checks,reg_read_data);
    $finish;
  end
  initial begin #1000000;$fatal(1,"P170 latency watchdog");end
endmodule
