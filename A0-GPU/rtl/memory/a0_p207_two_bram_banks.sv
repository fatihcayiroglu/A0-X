`timescale 1ns/1ps
// P207: Two actually instantiated P206 zero-scrubbed FPGA BRAM banks.
// A *shared* 8-bit host interface selects a complete independent
// P205/P203 committed controller. No incomplete operation may switch banks.
// Not atomic scanout/publication and not external VRAM.
module a0_p207_two_bram_banks #(
  parameter integer WORDS=1024,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy
);
  logic bank_sel_q,staged_q,selector_fault_q;
  wire b0_ready,b1_ready,b0_fault,b1_fault,b0_busy,b1_busy;
  wire [7:0] b0_rdata,b1_rdata;
  wire selector_hit=(host_addr==6'h30);
  wire transfer_0=host_valid && !selector_hit &&
      !selector_fault_q && !bank_sel_q;
  wire transfer_1=host_valid && !selector_hit &&
      !selector_fault_q && bank_sel_q;
  wire all_fault=selector_fault_q || b0_fault || b1_fault;
  assign fault=all_fault;
  assign busy=b0_busy || b1_busy || staged_q;
  assign host_ready=rst_n && !all_fault &&
      (selector_hit ? 1'b1 : (bank_sel_q ? b1_ready : b0_ready));
  assign host_rdata=selector_hit ?
      {3'd0,all_fault,b1_busy,b0_busy,staged_q,bank_sel_q} :
      (bank_sel_q ? b1_rdata : b0_rdata);

  a0_p206_committed_bram_top #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) bank0(
    .clk(clk),.rst_n(rst_n),
    .host_valid(transfer_0),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(b0_ready),.host_rdata(b0_rdata),
    .fault(b0_fault),.busy(b0_busy)
  );
  a0_p206_committed_bram_top #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR+32'(WORDS)),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) bank1(
    .clk(clk),.rst_n(rst_n),
    .host_valid(transfer_1),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(b1_ready),.host_rdata(b1_rdata),
    .fault(b1_fault),.busy(b1_busy)
  );

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      bank_sel_q<=0;staged_q<=0;selector_fault_q<=0;
    end else if(host_valid && host_write && host_ready)begin
      if(selector_hit)begin
        if(host_wdata>8'd1 || staged_q || b0_busy || b1_busy)
          selector_fault_q<=1;
        else bank_sel_q<=host_wdata[0];
      end else if(host_addr==6'h02 ||
                  (host_addr>=6'h04 && host_addr<=6'h0d))
        staged_q<=1;
      else if(host_addr==6'h00 && host_wdata==8'h02)
        staged_q<=0;
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       BASE_WORD_ADDR>32'hffff_ffff-2*WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P207 unsupported two-bank geometry");
  end
endmodule
