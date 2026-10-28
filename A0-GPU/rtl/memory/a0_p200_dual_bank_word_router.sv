`timescale 1ns/1ps
// P200: synthesizable physical-bank port demultiplexer for the P197 logical
// 48-bit word port and P199 atomic frame-epoch controller.
// Maps logical [BASE, BASE+FRAME_WORDS) to two independent downstream ports.
// This implements no storage, external memory timing, PCIe or DDR PHY.
module a0_p200_dual_bank_word_router #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000
)(
  input logic clk,rst_n,
  input logic cmd_valid,cmd_write,
  input logic [31:0] cmd_word_addr,
  input logic [47:0] cmd_pixel,
  output logic cmd_ready,
  output logic rsp_valid,rsp_error,
  output logic [47:0] rsp_pixel,
  input logic stage_bank,active_bank,write_permitted,read_permitted,
  output logic bank0_cmd_valid,bank1_cmd_valid,
  output logic bank0_cmd_write,bank1_cmd_write,
  output logic [31:0] bank0_cmd_addr,bank1_cmd_addr,
  output logic [47:0] bank0_cmd_pixel,bank1_cmd_pixel,
  input logic bank0_cmd_ready,bank1_cmd_ready,
  input logic bank0_rsp_valid,bank1_rsp_valid,
  input logic bank0_rsp_error,bank1_rsp_error,
  input logic [47:0] bank0_rsp_pixel,bank1_rsp_pixel,
  output logic write_commit,read_accept,read_complete,
  output logic fault,read_in_flight
);
  logic pending_q,pending_bank_q,fault_q;
  wire selected_bank=cmd_write ? stage_bank : active_bank;
  wire permitted=cmd_write ? write_permitted : read_permitted;
  wire cmd_in_range=cmd_word_addr>=BASE_WORD_ADDR &&
    (cmd_word_addr-BASE_WORD_ADDR)<FRAME_WORDS;
  wire issue=rst_n && !fault_q && cmd_valid && permitted &&
    !pending_q && !bank0_rsp_valid && !bank1_rsp_valid && cmd_in_range;
  wire [31:0] physical_addr=cmd_word_addr+
    (selected_bank ? 32'(FRAME_WORDS) : 32'd0);
  assign bank0_cmd_valid=issue && !selected_bank;
  assign bank1_cmd_valid=issue && selected_bank;
  assign bank0_cmd_write=cmd_write;
  assign bank1_cmd_write=cmd_write;
  assign bank0_cmd_addr=physical_addr;
  assign bank1_cmd_addr=physical_addr;
  assign bank0_cmd_pixel=cmd_pixel;
  assign bank1_cmd_pixel=cmd_pixel;
  assign cmd_ready=issue && (selected_bank ? bank1_cmd_ready : bank0_cmd_ready);
  assign write_commit=cmd_valid && cmd_ready && cmd_write;
  assign read_accept=cmd_valid && cmd_ready && !cmd_write;
  assign rsp_valid=bank0_rsp_valid || bank1_rsp_valid;
  assign rsp_error=(bank0_rsp_valid && bank0_rsp_error) ||
    (bank1_rsp_valid && bank1_rsp_error) ||
    (bank0_rsp_valid && bank1_rsp_valid) ||
    (rsp_valid && (!pending_q ||
      (pending_bank_q ? bank0_rsp_valid : bank1_rsp_valid)));
  assign rsp_pixel=bank0_rsp_valid ? bank0_rsp_pixel :
    bank1_rsp_valid ? bank1_rsp_pixel : 48'd0;
  assign read_complete=rsp_valid;
  assign read_in_flight=pending_q;
  assign fault=fault_q;
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      pending_q<=0;pending_bank_q<=0;fault_q<=0;
    end else begin
      if(cmd_valid && !cmd_in_range)
        fault_q<=1;
      if(read_accept)begin
        if(pending_q)fault_q<=1;
        else begin pending_q<=1;pending_bank_q<=selected_bank;end
      end
      if(rsp_valid)begin
        if(rsp_error || !pending_q)fault_q<=1;
        else pending_q<=0;
      end
    end
  end
  initial begin
    if(FRAME_WORDS<2 || FRAME_WORDS>65536 ||
      BASE_WORD_ADDR>(32'hffff_ffff-(2*FRAME_WORDS-1)))
      $fatal(1,"P200 unsupported two-bank word address geometry");
  end
endmodule
