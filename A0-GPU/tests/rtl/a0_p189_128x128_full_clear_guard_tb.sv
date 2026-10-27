`timescale 1ns/1ps
// P189: the specialized large-frame bank must never expose stale BRAM
// before a fully completed clear, or after the guard is withdrawn/reset.
module a0_p189_full_clear_guard_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,frame_initialized=0;
  logic req0_valid=0,req0_write=0;
  logic [13:0] req0_index=0;
  logic [47:0] req0_wdata=0;
  wire req0_ready,rsp0_valid,rsp0_error;
  wire [47:0] rsp0_rdata;
  a0_p138_dual_bank_framebuffer #(
    .FRAME_WIDTH(128),.FRAME_HEIGHT(128),.FULL_CLEAR_GUARD(1'b1)
  ) dut (
    .clk(clk),.rst_n(rst_n),.frame_initialized(frame_initialized),
    .req0_valid(req0_valid),.req0_ready(req0_ready),
    .req0_write(req0_write),.req0_index(req0_index),
    .req0_wdata(req0_wdata),.rsp0_valid(rsp0_valid),
    .rsp0_error(rsp0_error),.rsp0_rdata(rsp0_rdata),
    .req1_valid(1'b0),.req1_ready(),.req1_write(1'b0),
    .req1_index(14'd0),.req1_wdata(48'd0),
    .rsp1_valid(),.rsp1_error(),.rsp1_rdata()
  );
  task automatic transact(input logic write_en,
                           input logic [13:0] index,
                           input logic [47:0] data,
                           input logic [47:0] expected);
    begin
      @(negedge clk);
      req0_valid=1;req0_write=write_en;
      req0_index=index;req0_wdata=data;
      #1;
      if (req0_ready!==1'b1) $fatal(1,"P189 request not ready");
      @(posedge clk); #1;
      if (rsp0_valid!==1'b1 || rsp0_error!==1'b0)
        $fatal(1,"P189 missing/errored response");
      if (!write_en && rsp0_rdata!==expected)
        $fatal(1,"P189 read leak idx=%0d observed=%h expected=%h",
               index,rsp0_rdata,expected);
      @(negedge clk); req0_valid=0;
      @(posedge clk); #1;
      if (rsp0_valid!==1'b0) $fatal(1,"P189 stale response");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    transact(0,14'd2,48'd0,48'd0);
    transact(1,14'd2,48'hABCDEF123456,48'd0);
    transact(0,14'd2,48'd0,48'd0);
    // Exercise both physical banks and upper-half framebuffer addresses.
    transact(1,14'd3,48'h9876543210FE,48'd0);
    transact(1,14'd4096,48'h000102030405,48'd0);
    transact(1,14'd8191,48'h55AA55AA55AA,48'd0);
    transact(1,14'd8192,48'h010203040506,48'd0);
    transact(1,14'd16383,48'hDEAD98765432,48'd0);
    transact(0,14'd8191,48'd0,48'd0);
    transact(0,14'd16383,48'd0,48'd0);
    @(negedge clk); frame_initialized=1;
    transact(0,14'd2,48'd0,48'hABCDEF123456);
    transact(0,14'd3,48'd0,48'h9876543210FE);
    transact(0,14'd4096,48'd0,48'h000102030405);
    transact(0,14'd8191,48'd0,48'h55AA55AA55AA);
    transact(0,14'd8192,48'd0,48'h010203040506);
    transact(0,14'd16383,48'd0,48'hDEAD98765432);
    @(negedge clk); frame_initialized=0;
    transact(0,14'd2,48'd0,48'd0);
    transact(0,14'd4096,48'd0,48'd0);
    transact(0,14'd8191,48'd0,48'd0);
    transact(0,14'd16383,48'd0,48'd0);
    @(negedge clk); rst_n=0;
    repeat(2) @(negedge clk); rst_n=1;
    transact(0,14'd2,48'd0,48'd0);
    transact(0,14'd8191,48'd0,48'd0);
    transact(0,14'd16383,48'd0,48'd0);
    $display("P189_FULL_CLEAR_GUARD_PASS both banks high addresses zero before init and reset");
    $finish;
  end
  initial begin #2000; $fatal(1,"P189 guard test timeout"); end
endmodule
